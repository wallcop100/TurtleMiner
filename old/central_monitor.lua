-- Central Turtle Monitoring System
-- Receives and displays turtle status reports
-- Also maintains a central database of mined block coordinates.

local PROTOCOL = "TURTLE_STATUS"
local MINED_PROTOCOL = "TURTLE_MINED_DB"
local TIMEOUT = 15 -- seconds before marking turtle as disconnected
local REFRESH_RATE = 0.5 -- GUI refresh rate
local PAGE_CYCLE_TIME = 5 -- seconds between pages when list is long

-- Turtle tracking
local turtles = {}

-- Mined block database: key "x,y,z" => true
local minedBlocks = {}
local minedDirty = false
local minedMsgCount = 0
local lastMinedMsgAtUtcMs = 0
local lastMinedSenderId = nil
local lastMinedMsgType = nil

-- GUI paging state
local currentPage = 1
local lastPageSwitch = 0

local function coordKey(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

local function getMinedDbPath()
    -- Prefer floppy disk if present
    if fs.exists("/disk") then
        return "/disk/mined_areas.db"
    end
    return "/mined_areas.db"
end

local function loadMinedDb()
    local path = getMinedDbPath()
    if not fs.exists(path) then
        return
    end

    local ok, data = pcall(function()
        local h = fs.open(path, "r")
        if not h then return nil end
        local contents = h.readAll()
        h.close()
        return textutils.unserialize(contents)
    end)

    if ok and type(data) == "table" then
        minedBlocks = data
        local n = 0
        for _ in pairs(minedBlocks) do n = n + 1 end
        print("Loaded mined block database from " .. path .. " (" .. tostring(n) .. " entries)")
    else
        print("WARNING: Failed to load mined block database (using empty set)")
        minedBlocks = {}
    end
end

local function saveMinedDb()
    local path = getMinedDbPath()
    local ok, err = pcall(function()
        local h = fs.open(path, "w")
        if not h then error("Could not open " .. path .. " for writing") end
        h.write(textutils.serialize(minedBlocks))
        h.close()
    end)

    if not ok then
        print("ERROR saving mined block database: " .. tostring(err))
    else
        -- print("Saved mined block database to " .. path)
    end
end

-- Initialize modem
local function initModem()
    local modem = peripheral.find("modem")
    if not modem then
        error("No wireless modem found! Please attach a wireless modem.")
    end
    
    rednet.open(peripheral.getName(modem))
    print("Modem opened on: " .. peripheral.getName(modem))
    return true
end

-- Update turtle status
local function updateTurtle(id, data)
    turtles[id] = {
        id = id,
        label = data.label or ("Turtle-" .. id),
        fuel = data.fuel or 0,
        message = data.message or "No message",
        lastSeen = os.epoch("utc"),
        connected = true,
        slotsUsed = (data.inventory and data.inventory.slotsUsed) or 0
    }
end

-- Handle mined-area database messages
local function handleMinedMessage(senderId, message)
    minedMsgCount = minedMsgCount + 1
    lastMinedMsgAtUtcMs = os.epoch("utc")
    lastMinedSenderId = senderId
    lastMinedMsgType = message.type

    if message.type == "BLOCK_MINED" and message.x and message.y and message.z then
        local key = coordKey(math.floor(message.x), math.floor(message.y), math.floor(message.z))
        if not minedBlocks[key] then
            minedBlocks[key] = true
            minedDirty = true
        end
    elseif message.type == "CHECK_BLOCK" and message.x and message.y and message.z then
        local key = coordKey(math.floor(message.x), math.floor(message.y), math.floor(message.z))
        local mined = minedBlocks[key] == true
        local response = {
            type = "BLOCK_STATUS",
            x = message.x,
            y = message.y,
            z = message.z,
            mined = mined,
        }
        rednet.send(senderId, response, MINED_PROTOCOL)
    end
end

-- Check for timeouts
local function checkTimeouts()
    local currentTime = os.epoch("utc")
    for id, turtle in pairs(turtles) do
        local timeSince = (currentTime - turtle.lastSeen) / 1000
        if timeSince > TIMEOUT then
            turtle.connected = false
        end
    end
end

-- Draw GUI
local function drawGUI()
    term.clear()
    term.setCursorPos(1, 1)
    
    -- Header
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.clearLine()
    local width, height = term.getSize()
    local title = " Turtle Monitoring System "
    term.setCursorPos(math.floor((width - #title) / 2), 1)
    term.write(title)
    
    -- System info
    term.setBackgroundColor(colors.black)
    term.setCursorPos(1, 2)
    term.setTextColor(colors.lightGray)

    local activeCount = 0
    for _ in pairs(turtles) do
        activeCount = activeCount + 1
    end

    print("Central Computer ID: " .. os.getComputerID())
    print("Active Turtles: " .. activeCount)
    do
        local entries = 0
        for _ in pairs(minedBlocks) do entries = entries + 1 end

        local lastAge = "never"
        if lastMinedMsgAtUtcMs and lastMinedMsgAtUtcMs > 0 then
            local ageSec = math.floor((os.epoch("utc") - lastMinedMsgAtUtcMs) / 1000)
            lastAge = tostring(ageSec) .. "s ago"
        end

        print(string.format(
            "Mined DB: %d entries | recv: %d | last: %s | from: %s | type: %s",
            entries,
            minedMsgCount,
            lastAge,
            tostring(lastMinedSenderId),
            tostring(lastMinedMsgType)
        ))
    end
    print(string.rep("-", width))
    
    -- Turtle list
    local totalPages = 1
    local contentTop = 6

    if next(turtles) == nil then
        term.setTextColor(colors.gray)
        term.setCursorPos(1, contentTop)
        print("No turtles connected...")
    else
        -- Build a stable, sorted list of turtle IDs
        local ids = {}
        for id in pairs(turtles) do
            table.insert(ids, id)
        end
        table.sort(ids)

        local contentBottom = height - 1 -- reserve last line for footer
        local rowsAvailable = contentBottom - contentTop + 1
        local linesPerTurtle = 4
        local turtlesPerPage = math.max(1, math.floor(rowsAvailable / linesPerTurtle))

        local totalTurtles = #ids
        totalPages = math.max(1, math.ceil(totalTurtles / turtlesPerPage))

        -- Clamp current page in case turtle count shrank
        if currentPage > totalPages then
            currentPage = totalPages
        end

        -- Auto-cycle pages when there are more turtles than fit on screen
        if totalPages > 1 then
            local now = os.epoch("utc") / 1000
            if lastPageSwitch == 0 then
                lastPageSwitch = now
            end
            if now - lastPageSwitch >= PAGE_CYCLE_TIME then
                currentPage = currentPage + 1
                if currentPage > totalPages then
                    currentPage = 1
                end
                lastPageSwitch = now
            end
        else
            currentPage = 1
        end

        local startIndex = (currentPage - 1) * turtlesPerPage + 1
        local endIndex = math.min(startIndex + turtlesPerPage - 1, totalTurtles)

        local y = contentTop
        for i = startIndex, endIndex do
            local id = ids[i]
            local turtle = turtles[id]
            if not turtle then
                goto continue
            end

            term.setCursorPos(1, y)
            
            -- Status indicator
            if turtle.connected then
                term.setTextColor(colors.lime)
                term.write("[ONLINE] ")
            else
                term.setTextColor(colors.red)
                term.write("[OFFLINE]")
            end
            
            -- Turtle info
            term.setTextColor(colors.white)
            term.write(" " .. turtle.label)
            
            term.setCursorPos(1, y + 1)
            term.setTextColor(colors.lightGray)
            term.write("  ID: " .. id)
            term.write(" | Fuel: ")
            
            -- Fuel color coding
            if turtle.fuel == "unlimited" then
                term.setTextColor(colors.lime)
                term.write("Unlimited")
            elseif turtle.fuel > 1000 then
                term.setTextColor(colors.lime)
                term.write(turtle.fuel)
            elseif turtle.fuel > 100 then
                term.setTextColor(colors.yellow)
                term.write(turtle.fuel)
            else
                term.setTextColor(colors.red)
                term.write(turtle.fuel)
            end
            
            term.setTextColor(colors.lightGray)
            term.write(" | Inv: " .. turtle.slotsUsed .. "/16")
            
            term.setCursorPos(1, y + 2)
            term.setTextColor(colors.cyan)
            term.write("  " .. turtle.message)
            
            y = y + linesPerTurtle
            ::continue::
        end
    end
    
    -- Footer
    term.setCursorPos(1, height)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()

    local footerText = " Press 'Q' to quit | Listening for turtles..."
    if totalPages > 1 then
        footerText = footerText .. string.format(" | Page %d/%d", currentPage, totalPages)
    end

    term.write(footerText)
    term.setBackgroundColor(colors.black)
end

-- Handle incoming turtle status messages
local function handleMessage(senderId, message)
    if message.type == "TEST" then
        -- Respond to test messages
        rednet.send(senderId, {type = "ACK", id = os.getComputerID()}, PROTOCOL)
        print("Test message from Turtle " .. senderId .. " - ACK sent")
    else
        -- Regular status update
        updateTurtle(senderId, message)
    end
end

-- Listen for status messages in background
local function listenForMessages()
    while true do
        local senderId, message, protocol = rednet.receive(PROTOCOL, 1)
        if senderId and protocol == PROTOCOL then
            local success, err = pcall(handleMessage, senderId, message)
            if not success then
                print("Error handling message: " .. tostring(err))
            end
        end
    end
end

-- Listen for mined-area database messages
local function listenForMinedMessages()
    while true do
        local senderId, message, protocol = rednet.receive(MINED_PROTOCOL, 1)
        if senderId and protocol == MINED_PROTOCOL and type(message) == "table" then
            local success, err = pcall(handleMinedMessage, senderId, message)
            if not success then
                print("Error handling mined DB message: " .. tostring(err))
            end
        end
    end
end

-- Check for quit key
local function checkQuit()
    while true do
        local event, key = os.pullEvent("key")
        if key == keys.q then
            return true
        end
    end
end

-- Update GUI periodically
local function updateGUI()
    while true do
        checkTimeouts()
        drawGUI()
        sleep(REFRESH_RATE)
    end
end

-- Periodically persist mined block database
local function autosaveMinedDb()
    while true do
        if minedDirty then
            saveMinedDb()
            minedDirty = false
        end
        sleep(10)
    end
end

-- Main program
print("=== Turtle Monitoring System ===")
print("Initializing...")

-- Initialize modem
local success, err = pcall(initModem)
if not success then
    printError("ERROR: " .. tostring(err))
    return
end

print("System ready! Loading mined-area database...")
loadMinedDb()
print("Starting GUI and listeners...")
sleep(1)

-- Draw initial GUI
drawGUI()

-- Run all tasks in parallel
parallel.waitForAny(
    listenForMessages,
    listenForMinedMessages,
    updateGUI,
    autosaveMinedDb,
    checkQuit
)

-- Cleanup
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.white)
term.setBackgroundColor(colors.black)
print("Monitoring system stopped.")
rednet.close()
