-- Version: 3.2.0
-- Added: Wired-bridge system – packets are forwarded between servers on wired network
-- Added: Mesh network relay system for extended communication range
-- Central Turtle Monitoring System - TOUCHSCREEN EDITION

local PROTOCOL          = "TURTLE_STATUS"
local MINED_PROTOCOL    = "TURTLE_MINED_DB"
local COMMAND_PROTOCOL  = "TURTLE_COMMAND"
local POSITION_PROTOCOL = "TURTLE_POSITION"
local BRIDGE_PROTOCOL   = "TURTLE_BRIDGE"    -- server-to-server wired bridge
local TIMEOUT = 15
local REFRESH_RATE = 0.5

-- Turtle tracking
local turtles = {}
local turtlePositions = {}
local minedBlocks = {}
local minedDirty = false
local minedMsgCount = 0

-- Relay tracking
local recentlyRelayed = {}
local MAX_RELAY_HOPS = 3
local RELAY_CACHE_SIZE = 100

-- Bridge (wired peer server) tracking
local wirelessModemName = nil     -- name of the wireless modem peripheral, if any
local wiredModemName    = nil       -- name of the wired modem peripheral, if any
local bridgePeers     = {}        -- [computerId] = { lastSeen }
local recentlyBridged = {}        -- dedup cache for bridge packets
local BRIDGE_CACHE_SIZE = 200

-- GUI state
local currentPage = 1
local showCommandMenu = false
local selectedTurtleId = nil
local commandInput = ""
local inputMode = nil

-- Monitor/display setup
local monitor = peripheral.find("monitor")
local display = monitor or term
if monitor then
    monitor.setTextScale(0.5)
    print("Monitor detected - using touchscreen")
else
    print("No monitor - using terminal")
end

-- Button system
local buttons = {}

local function createButton(x, y, width, height, text, color, callback)
    return {
        x = x, y = y, width = width, height = height,
        text = text, color = color or colors.blue,
        callback = callback
    }
end

local function isButtonClicked(button, clickX, clickY)
    return clickX >= button.x and clickX < button.x + button.width and
           clickY >= button.y and clickY < button.y + button.height
end

local function drawButton(button, pressed)
    local bgColor = pressed and colors.lightGray or button.color
    display.setBackgroundColor(bgColor)
    display.setTextColor(colors.white)
    
    for dy = 0, button.height - 1 do
        display.setCursorPos(button.x, button.y + dy)
        display.write(string.rep(" ", button.width))
    end
    
    local textY = button.y + math.floor(button.height / 2)
    local textX = button.x + math.floor((button.width - #button.text) / 2)
    display.setCursorPos(textX, textY)
    display.write(button.text)
end

-- Database functions
local function coordKey(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

local function getPath(name)
    return fs.exists("/disk") and ("/disk/" .. name) or ("/" .. name)
end

local function loadDb(name)
    local path = getPath(name)
    if not fs.exists(path) then return {} end
    
    local ok, data = pcall(function()
        local h = fs.open(path, "r")
        if not h then return nil end
        local contents = h.readAll()
        h.close()
        return textutils.unserialize(contents)
    end)
    
    return (ok and type(data) == "table") and data or {}
end

local function saveDb(name, data)
    pcall(function()
        local h = fs.open(getPath(name), "w")
        if h then
            h.write(textutils.serialize(data))
            h.close()
        end
    end)
end

-- Network functions
local function initModem()
    -- Open wireless modem (optional - for direct turtle communication)
    local wirelessModem = peripheral.find("modem", function(_, m) return m.isWireless() end)
    if wirelessModem then
        wirelessModemName = peripheral.getName(wirelessModem)
        rednet.open(wirelessModemName)
        print("Wireless modem opened: " .. wirelessModemName)
    else
        print("No wireless modem - running in bridge-only mode")
    end

    -- Open wired modem (optional - enables server bridging)
    local wiredModem = peripheral.find("modem", function(_, m) return not m.isWireless() end)
    if wiredModem then
        wiredModemName = peripheral.getName(wiredModem)
        rednet.open(wiredModemName)
        print("Wired modem opened: " .. wiredModemName .. " (bridge enabled)")
    else
        print("No wired modem found - bridge disabled")
    end

    -- Need at least one modem to do anything useful
    if not wirelessModem and not wiredModem then
        error("No modem found! Attach a wireless and/or wired modem.")
    end

    return true
end

-- Relay system functions
local function cleanRelayCache()
    local cacheSize = 0
    for _ in pairs(recentlyRelayed) do cacheSize = cacheSize + 1 end
    
    if cacheSize > RELAY_CACHE_SIZE then
        local toRemove = {}
        local count = 0
        for msgId in pairs(recentlyRelayed) do
            table.insert(toRemove, msgId)
            count = count + 1
            if count > RELAY_CACHE_SIZE / 2 then break end
        end
        for _, msgId in ipairs(toRemove) do
            recentlyRelayed[msgId] = nil
        end
    end
end

local function getMessageId(senderId, timestamp)
    return tostring(senderId) .. "_" .. tostring(timestamp)
end

local function relayMessage(senderId, message, protocol)
    -- Don't relay our own messages
    if senderId == os.getComputerID() then return end
    
    -- Check relay hops
    local hops = message.relayHops or 0
    if hops >= MAX_RELAY_HOPS then return end
    
    -- Check if already relayed
    local msgId = getMessageId(message.originalSender or senderId, message.timestamp or os.epoch("utc"))
    if recentlyRelayed[msgId] then return end
    
    -- Mark as relayed
    recentlyRelayed[msgId] = true
    cleanRelayCache()
    
    -- Create relayed version
    local relayedMsg = {}
    for k, v in pairs(message) do relayedMsg[k] = v end
    relayedMsg.relayHops = hops + 1
    relayedMsg.relayedBy = os.getComputerID()
    relayedMsg.originalSender = relayedMsg.originalSender or senderId
    
    -- Broadcast wirelessly (only if a wireless modem is attached)
    if wirelessModemName then
        pcall(function()
            rednet.broadcast(relayedMsg, protocol)
        end)
    end
end

-- =============================================================================
-- Bridge system: forwards packets between servers connected by wired network
-- =============================================================================

-- Clean the bridge dedup cache when it gets too large
local function cleanBridgeCache()
    local size = 0
    for _ in pairs(recentlyBridged) do size = size + 1 end
    if size > BRIDGE_CACHE_SIZE then
        local toRemove = {}
        local count = 0
        for k in pairs(recentlyBridged) do
            table.insert(toRemove, k)
            count = count + 1
            if count > BRIDGE_CACHE_SIZE / 2 then break end
        end
        for _, k in ipairs(toRemove) do recentlyBridged[k] = nil end
    end
end

-- Unique ID for a bridge packet so we never process the same one twice
local function bridgePacketId(originServerId, originalSenderId, ts)
    return tostring(originServerId) .. "_" .. tostring(originalSenderId) .. "_" .. tostring(ts)
end

-- Forward a turtle packet (already received and processed locally) to all wired peers.
-- originServerId: the server that first bridged this packet (us, unless re-bridging).
-- originalSenderId: the turtle/computer that sent the original packet.
local function bridgeToWired(protocol, originalSenderId, payload, originServerId)
    if not wiredModemName then return end

    originServerId = originServerId or os.getComputerID()

    -- Stamp a bridgeId so receiving servers can dedup
    local ts = payload.timestamp or os.epoch("utc")
    local bid = bridgePacketId(originServerId, originalSenderId, ts)

    -- Don't re-bridge something we already bridged
    if recentlyBridged[bid] then return end
    recentlyBridged[bid] = true
    cleanBridgeCache()

    local bridgeMsg = {
        type             = "BRIDGE_PACKET",
        innerProtocol    = protocol,
        originalSenderId = originalSenderId,
        originServerId   = originServerId,
        bridgeId         = bid,
        payload          = payload,
        timestamp        = ts,
    }

    pcall(function()
        rednet.broadcast(bridgeMsg, BRIDGE_PROTOCOL)
    end)
end

-- Process an incoming BRIDGE_PACKET from a peer server on the wired network.
-- Returns true if the packet was new and was processed.
local handleBridgePacket   -- forward-declared; defined after handleMinedMessage etc.

local function updateTurtle(id, data)
    local turtle = turtles[id] or {}
    
    -- Use originalSender if this is a relayed message
    local actualId = data.originalSender or id
    turtle.id = actualId
    
    turtle.label = data.label or ("Turtle-" .. actualId)
    turtle.fuel = data.fuel or 0
    turtle.message = data.message or turtle.message or "Idle"
    turtle.lastSeen = os.epoch("utc")
    turtle.connected = true
    turtle.slotsUsed = (data.inventory and data.inventory.slotsUsed) or 0
    
    -- Track if message was relayed
    if data.relayHops and data.relayHops > 0 then
        turtle.relayed = true
        turtle.relayHops = data.relayHops
    else
        turtle.relayed = false
        turtle.relayHops = 0
    end
    
    if data.position then
        turtle.currentX = data.position.x
        turtle.currentY = data.position.y
        turtle.currentZ = data.position.z
    end
    
    -- Preserve existing values if not provided in update
    turtle.oresMined = data.oresMined or turtle.oresMined
    turtle.currentBranch = data.currentBranch or turtle.currentBranch
    turtle.targetY = data.targetY or turtle.targetY
    turtle.focusedOre = data.focusedOre or turtle.focusedOre
    turtle.pattern = data.pattern or turtle.pattern
    turtle.currentY = data.currentY or turtle.currentY
    turtle.miningY = data.miningY or turtle.miningY
    turtle.hasGPS = data.hasGPS or turtle.hasGPS
    turtle.distanceFromHome = data.distanceFromHome or turtle.distanceFromHome
    
    turtles[actualId] = turtle
end

local function handleMinedMessage(senderId, message)
    minedMsgCount = minedMsgCount + 1
    
    if message.type == "BLOCK_MINED" and message.x and message.y and message.z then
        local turtleId = message.turtleId or senderId
        local hasGPS = message.hasGPS or false
        local key = hasGPS and coordKey(message.x, message.y, message.z) 
                    or ("T" .. turtleId .. "_" .. coordKey(message.x, message.y, message.z))
        
        if not minedBlocks[key] then
            minedBlocks[key] = true
            minedDirty = true
        end
    elseif message.type == "CHECK_BLOCK" and message.x and message.y and message.z then
        local turtleId = message.turtleId or senderId
        local hasGPS = message.hasGPS or false
        local key = hasGPS and coordKey(message.x, message.y, message.z)
                    or ("T" .. turtleId .. "_" .. coordKey(message.x, message.y, message.z))
        
        rednet.send(senderId, {
            type = "BLOCK_STATUS",
            x = message.x, y = message.y, z = message.z,
            mined = minedBlocks[key] == true
        }, MINED_PROTOCOL)
    end
end

local function handlePositionMessage(senderId, message)
    if message.type == "SAVE_HOME_POSITION" and message.turtleId then
        turtlePositions[message.turtleId] = {
            homePosition = message.position,
            homeFacing = message.facing,
            lastUpdated = os.epoch("utc")
        }
        saveDb("turtle_positions.db", turtlePositions)
        rednet.send(senderId, {type = "POSITION_SAVED", turtleId = message.turtleId}, POSITION_PROTOCOL)
    elseif message.type == "REQUEST_HOME_POSITION" and message.turtleId then
        local posData = turtlePositions[message.turtleId]
        if posData then
            rednet.send(senderId, {
                type = "HOME_POSITION",
                turtleId = message.turtleId,
                position = posData.homePosition,
                facing = posData.homeFacing
            }, POSITION_PROTOCOL)
        end
    end
end

local function sendCommandToTurtle(turtleId, command, params)
    local cmdMsg = {command = command, params = params or {}, timestamp = os.epoch("utc")}
    -- Broadcast on wireless so nearby turtles receive the command directly
    if wirelessModemName then
        rednet.broadcast(cmdMsg, COMMAND_PROTOCOL)
    end
    -- Bridge to wired peers so turtles near remote servers also receive it
    bridgeToWired(COMMAND_PROTOCOL, os.getComputerID(), cmdMsg)

    local startTime = os.epoch("utc") / 1000
    while (os.epoch("utc") / 1000 - startTime) < 3 do
        local senderId, response = rednet.receive(COMMAND_PROTOCOL, 1)
        if senderId == turtleId and response and response.type == "COMMAND_ACK" then
            return true
        end
    end
    return false
end

-- Drawing functions
local function drawHeader()
    local width = display.getSize()
    display.setBackgroundColor(colors.blue)
    display.setTextColor(colors.white)
    display.setCursorPos(1, 1)
    display.clearLine()
    local title = " TURTLE COMMAND CENTER "
    display.setCursorPos(math.floor((width - #title) / 2) + 1, 1)
    display.write(title)
end

local function drawStats()
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.lightGray)
    display.setCursorPos(1, 2)
    display.clearLine()
    
    local active = 0
    for _, t in pairs(turtles) do
        if t.connected then active = active + 1 end
    end
    
    local posCount, minedCount, peerCount = 0, 0, 0
    for _ in pairs(turtlePositions) do posCount  = posCount  + 1 end
    for _ in pairs(minedBlocks)     do minedCount = minedCount + 1 end

    -- Count live bridge peers (seen within last 30 s)
    local now = os.epoch("utc")
    for _, p in pairs(bridgePeers) do
        if (now - p.lastSeen) / 1000 < 30 then peerCount = peerCount + 1 end
    end

    local statsLine
    if wiredModemName then
        statsLine = string.format("Active: %d | Mined: %d | Peers: %d", active, minedCount, peerCount)
    else
        statsLine = string.format("Active: %d | Saved: %d | Mined: %d", active, posCount, minedCount)
    end
    display.write(statsLine)
end

local function drawTurtleCard(turtle, x, y, width, height)
    display.setBackgroundColor(colors.lightGray)
    for dy = 0, height - 1 do
        display.setCursorPos(x, y + dy)
        display.write(string.rep(" ", width))
    end
    
    -- Line 0: Status + Name
    display.setCursorPos(x + 1, y)
    display.setTextColor(turtle.connected and colors.lime or colors.red)
    display.write(turtle.connected and "[ON]" or "[OFF]")
    
    -- Relay indicator (shows if message was relayed)
    if turtle.relayed and turtle.relayHops and turtle.relayHops > 0 then
        display.setTextColor(colors.orange)
        display.write(" R" .. turtle.relayHops)
    end
    
    display.setTextColor(colors.black)
    local nameStart = (turtle.relayed and 12) or 7
    display.setCursorPos(x + nameStart, y)
    local name = turtle.label
    local maxNameLen = width - nameStart - 1
    if #name > maxNameLen then name = name:sub(1, maxNameLen - 3) .. "..." end
    display.write(name)
    
    -- Line 1: ID + Fuel + Inventory
    display.setTextColor(colors.gray)
    display.setCursorPos(x + 1, y + 1)
    display.write("ID:" .. turtle.id)
    
    display.setCursorPos(x + 10, y + 1)
    display.write("Fuel:")
    display.setCursorPos(x + 15, y + 1)
    if turtle.fuel == "unlimited" then
        display.setTextColor(colors.lime)
        display.write("Unlim")
    elseif turtle.fuel > 1000 then
        display.setTextColor(colors.lime)
        display.write(turtle.fuel)
    elseif turtle.fuel > 100 then
        display.setTextColor(colors.yellow)
        display.write(turtle.fuel)
    else
        display.setTextColor(colors.red)
        display.write(turtle.fuel)
    end
    
    display.setTextColor(colors.gray)
    display.setCursorPos(x + width - 8, y + 1)
    display.write("Inv:" .. turtle.slotsUsed)
    
    -- Line 2: Position
    display.setCursorPos(x + 1, y + 2)
    if turtle.currentX and turtle.currentY and turtle.currentZ then
        local pos = string.format("Pos: (%d,%d,%d)", turtle.currentX, turtle.currentY, turtle.currentZ)
        if #pos > width - 2 then
            pos = string.format("Pos: Y:%d", turtle.currentY)
        end
        display.write(pos)
    else
        display.write("Pos: Unknown")
    end
    
    -- Line 3: Mining stats
    display.setCursorPos(x + 1, y + 3)
    if turtle.oresMined then
        display.write("Ores:" .. turtle.oresMined)
    end
    if turtle.currentBranch then
        local branchText = " | Branch #" .. turtle.currentBranch
        if width > 30 then
            display.write(branchText)
        end
    end
    
    -- Line 4: Target Y + Focused Ore
    display.setCursorPos(x + 1, y + 4)
    if turtle.targetY then
        display.write("Target Y:" .. turtle.targetY)
    end
    if turtle.focusedOre and width > 30 then
        display.setCursorPos(x + 20, y + 4)
        display.write("Ore:" .. turtle.focusedOre)
    end
    
    -- Line 5: Status message
    if turtle.message then
        display.setCursorPos(x + 1, y + 5)
        display.setTextColor(colors.cyan)
        local msg = turtle.message
        if #msg > width - 3 then
            msg = msg:sub(1, width - 6) .. "..."
        end
        display.write(msg)
    end
    
    -- Line 6: Last seen (if card is tall enough)
    if height >= 7 and turtle.lastSeen then
        display.setCursorPos(x + 1, y + 6)
        display.setTextColor(colors.gray)
        local age = math.floor((os.epoch("utc") - turtle.lastSeen) / 1000)
        display.write("Updated: " .. age .. "s ago")
    end
end

local function drawCommandMenu()
    buttons = {}
    local width, height = display.getSize()
    display.setBackgroundColor(colors.black)
    display.clear()
    
    local menuWidth = math.min(40, width - 4)
    local menuHeight = math.min(20, height - 4)
    local menuX = math.floor((width - menuWidth) / 2) + 1
    local menuY = math.floor((height - menuHeight) / 2) + 1
    
    -- Background
    display.setBackgroundColor(colors.gray)
    for dy = 0, menuHeight - 1 do
        display.setCursorPos(menuX, menuY + dy)
        display.write(string.rep(" ", menuWidth))
    end
    
    -- Header
    display.setBackgroundColor(colors.blue)
    display.setTextColor(colors.white)
    display.setCursorPos(menuX, menuY)
    local title = " Command Turtle #" .. selectedTurtleId .. " "
    display.write(title .. string.rep(" ", menuWidth - #title))
    
    -- Input modes
    if inputMode == "targetY" then
        display.setBackgroundColor(colors.gray)
        display.setTextColor(colors.white)
        display.setCursorPos(menuX + 2, menuY + 2)
        display.write("Enter Target Y (-64 to 320):")
        display.setCursorPos(menuX + 2, menuY + 3)
        display.write("> " .. commandInput .. "_")
        
        local okBtn = createButton(menuX + 5, menuY + 5, 10, 3, "OK", colors.green, function()
            local y = tonumber(commandInput)
            if y and y >= -64 and y <= 320 then
                sendCommandToTurtle(selectedTurtleId, "SET_TARGET_Y", {targetY = y})
                showCommandMenu = false
                inputMode = nil
                commandInput = ""
            end
        end)
        
        local cancelBtn = createButton(menuX + menuWidth - 15, menuY + 5, 10, 3, "Cancel", colors.red, function()
            showCommandMenu = false
            inputMode = nil
            commandInput = ""
        end)
        
        table.insert(buttons, okBtn)
        table.insert(buttons, cancelBtn)
        drawButton(okBtn)
        drawButton(cancelBtn)
        
    elseif inputMode == "oreType" then
        display.setBackgroundColor(colors.gray)
        display.setTextColor(colors.white)
        display.setCursorPos(menuX + 2, menuY + 2)
        display.write("Select Ore Type:")
        
        local ores = {
            {name = "Diamond", value = "diamond"},
            {name = "Emerald", value = "emerald"},
            {name = "Gold", value = "gold"},
            {name = "Iron", value = "iron"},
            {name = "All Ores", value = "all"}
        }
        
        local btnY = menuY + 4
        for _, ore in ipairs(ores) do
            local btn = createButton(menuX + 2, btnY, menuWidth - 4, 2, ore.name, colors.blue, function()
                sendCommandToTurtle(selectedTurtleId, "FOCUS_ORE", {oreType = ore.value})
                showCommandMenu = false
                inputMode = nil
            end)
            table.insert(buttons, btn)
            drawButton(btn)
            btnY = btnY + 3
        end
    else
        -- Main menu
        local commands = {
            {name = "H Return Home", command = "RETURN_HOME", color = colors.orange},
            {name = "Y Set Target Y", command = "SET_TARGET_Y", color = colors.blue},
            {name = "O Focus Ore", command = "FOCUS_ORE", color = colors.blue},
            {name = "R Resume Mining", command = "RESUME_MINING", color = colors.green},
            {name = "S Request Status", command = "REQUEST_STATUS", color = colors.blue},
            {name = "X Cancel", command = nil, color = colors.red}
        }
        
        local btnY = menuY + 2
        for _, cmd in ipairs(commands) do
            local btn = createButton(menuX + 2, btnY, menuWidth - 4, 2, cmd.name, cmd.color, function()
                if cmd.command == "SET_TARGET_Y" then
                    inputMode = "targetY"
                    commandInput = ""
                elseif cmd.command == "FOCUS_ORE" then
                    inputMode = "oreType"
                elseif cmd.command then
                    sendCommandToTurtle(selectedTurtleId, cmd.command, {})
                    showCommandMenu = false
                else
                    showCommandMenu = false
                end
            end)
            table.insert(buttons, btn)
            drawButton(btn)
            btnY = btnY + 3
        end
    end
end

local function drawMainScreen()
    buttons = {}
    local width, height = display.getSize()
    display.setBackgroundColor(colors.black)
    display.clear()
    
    drawHeader()
    drawStats()
    
    local ids = {}
    for id in pairs(turtles) do table.insert(ids, id) end
    table.sort(ids)
    
    if #ids == 0 then
        display.setTextColor(colors.gray)
        display.setCursorPos(2, 5)
        display.write("No turtles connected...")
        return
    end
    
    local cardHeight = 8  -- Full status display
    local cardSpacing = 1
    local cardsPerPage = math.floor((height - 6) / (cardHeight + cardSpacing))
    local totalPages = math.ceil(#ids / cardsPerPage)
    if currentPage > totalPages then currentPage = totalPages end
    
    local startIndex = (currentPage - 1) * cardsPerPage + 1
    local endIndex = math.min(startIndex + cardsPerPage - 1, #ids)
    
    local cardY = 4
    for i = startIndex, endIndex do
        local id = ids[i]
        drawTurtleCard(turtles[id], 2, cardY, width - 2, cardHeight)
        
        local btn = createButton(2, cardY, width - 2, cardHeight, "", colors.lightGray, function()
            selectedTurtleId = id
            showCommandMenu = true
            inputMode = nil
            commandInput = ""
        end)
        table.insert(buttons, btn)
        
        cardY = cardY + cardHeight + cardSpacing
    end
    
    -- Navigation
    if currentPage > 1 then
        local prevBtn = createButton(2, height - 1, 12, 1, "< Prev", colors.blue, function()
            currentPage = currentPage - 1
        end)
        table.insert(buttons, prevBtn)
        drawButton(prevBtn)
    end
    
    if currentPage < totalPages then
        local nextBtn = createButton(width - 13, height - 1, 12, 1, "Next >", colors.blue, function()
            currentPage = currentPage + 1
        end)
        table.insert(buttons, nextBtn)
        drawButton(nextBtn)
    end
    
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    local pageText = string.format("Page %d/%d", currentPage, totalPages)
    display.setCursorPos(math.floor((width - #pageText) / 2) + 1, height - 1)
    display.write(pageText)
    
    local refreshBtn = createButton(width - 10, 2, 10, 1, "Refresh", colors.green, function() end)
    table.insert(buttons, refreshBtn)
    drawButton(refreshBtn)
end

-- Event handlers
local function handleTouch(x, y)
    for _, btn in ipairs(buttons) do
        if isButtonClicked(btn, x, y) then
            drawButton(btn, true)
            sleep(0.1)
            if btn.callback then btn.callback() end
            return true
        end
    end
    return false
end

local function checkTimeouts()
    local now = os.epoch("utc")
    for _, turtle in pairs(turtles) do
        if (now - turtle.lastSeen) / 1000 > TIMEOUT then
            turtle.connected = false
        end
    end
end

-- =============================================================================
-- handleBridgePacket definition (forward-declared above)
-- Called when we receive a BRIDGE_PROTOCOL packet from a wired peer server.
-- =============================================================================
handleBridgePacket = function(senderId, bridgeMsg)
    if type(bridgeMsg) ~= "table" then return false end
    if bridgeMsg.type ~= "BRIDGE_PACKET" then return false end

    -- Dedup: ignore if we already processed this bridge packet
    local bid = bridgeMsg.bridgeId
    if not bid then return false end
    if recentlyBridged[bid] then return false end
    recentlyBridged[bid] = true
    cleanBridgeCache()

    -- Track the peer server
    local peerId = bridgeMsg.originServerId or senderId
    bridgePeers[peerId] = { lastSeen = os.epoch("utc") }

    -- Process the inner payload as if we received it directly from the turtle
    local proto  = bridgeMsg.innerProtocol
    local origId = bridgeMsg.originalSenderId
    local payload = bridgeMsg.payload
    if not (proto and origId and payload) then return false end

    if proto == PROTOCOL then
        if payload.type ~= "TEST" then
            updateTurtle(origId, payload)
        end
        relayMessage(origId, payload, PROTOCOL)

    elseif proto == MINED_PROTOCOL then
        pcall(handleMinedMessage, origId, payload)
        relayMessage(origId, payload, MINED_PROTOCOL)

    elseif proto == POSITION_PROTOCOL then
        pcall(handlePositionMessage, origId, payload)
        relayMessage(origId, payload, POSITION_PROTOCOL)

    elseif proto == COMMAND_PROTOCOL then
        -- Re-broadcast commands from peers so our local turtles receive them too
        if wirelessModemName then
            pcall(function()
                rednet.broadcast(payload, COMMAND_PROTOCOL)
            end)
        end
    end

    -- Re-bridge to any further wired peers (hop through this server's wired modem).
    -- The dedup cache prevents infinite loops.
    bridgeToWired(proto, origId, payload, bridgeMsg.originServerId)

    return true
end

-- Main loops
local function listenForMessages()
    while true do
        local senderId, message = rednet.receive(PROTOCOL, 1)
        if senderId then
            -- Ignore our own bridged re-broadcasts coming back
            if senderId ~= os.getComputerID() then
                if message.type == "TEST" then
                    rednet.send(senderId, {type = "ACK", id = os.getComputerID()}, PROTOCOL)
                else
                    updateTurtle(senderId, message)
                end
                -- Relay wirelessly AND forward to wired peers
                relayMessage(senderId, message, PROTOCOL)
                bridgeToWired(PROTOCOL, senderId, message)
            end
        end
    end
end

local function listenForMinedMessages()
    while true do
        local senderId, message = rednet.receive(MINED_PROTOCOL, 1)
        if senderId and type(message) == "table" then
            if senderId ~= os.getComputerID() then
                pcall(handleMinedMessage, senderId, message)
                relayMessage(senderId, message, MINED_PROTOCOL)
                bridgeToWired(MINED_PROTOCOL, senderId, message)
            end
        end
    end
end

local function listenForPositionMessages()
    while true do
        local senderId, message = rednet.receive(POSITION_PROTOCOL, 1)
        if senderId and type(message) == "table" then
            if senderId ~= os.getComputerID() then
                pcall(handlePositionMessage, senderId, message)
                relayMessage(senderId, message, POSITION_PROTOCOL)
                bridgeToWired(POSITION_PROTOCOL, senderId, message)
            end
        end
    end
end

-- Listens for packets from peer servers on the wired bridge network
local function listenForBridgeMessages()
    if not wiredModemName then
        -- No wired modem - this coroutine just sleeps forever so parallel still works
        while true do sleep(60) end
    end
    while true do
        local senderId, message = rednet.receive(BRIDGE_PROTOCOL, 1)
        if senderId and senderId ~= os.getComputerID() then
            pcall(handleBridgePacket, senderId, message)
        end
    end
end

local function handleInput()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        
        if event == "monitor_touch" or event == "mouse_click" then
            handleTouch(p2, p3)
        elseif event == "char" and inputMode == "targetY" then
            if p1:match("[0-9]") or (p1 == "-" and #commandInput == 0) then
                commandInput = commandInput .. p1
            end
        elseif event == "key" and inputMode == "targetY" then
            if p1 == keys.backspace and #commandInput > 0 then
                commandInput = commandInput:sub(1, -2)
            elseif p1 == keys.enter then
                for _, btn in ipairs(buttons) do
                    if btn.text == "OK" and btn.callback then
                        btn.callback()
                        break
                    end
                end
            end
        end
    end
end

local function updateGUI()
    while true do
        checkTimeouts()
        if showCommandMenu then
            drawCommandMenu()
        else
            drawMainScreen()
        end
        sleep(REFRESH_RATE)
    end
end

local function autosaveMinedDb()
    while true do
        if minedDirty then
            saveDb("mined_areas.db", minedBlocks)
            minedDirty = false
        end
        sleep(10)
    end
end

-- Startup
print("=== Turtle Command Center (Touchscreen) ===")
if not pcall(initModem) then
    printError("ERROR: Modem initialization failed")
    return
end

minedBlocks = loadDb("mined_areas.db")
turtlePositions = loadDb("turtle_positions.db")
print("Databases loaded")
sleep(1)

parallel.waitForAny(
    listenForMessages,
    listenForMinedMessages,
    listenForPositionMessages,
    listenForBridgeMessages,
    updateGUI,
    autosaveMinedDb,
    handleInput
)

display.setBackgroundColor(colors.black)
display.setTextColor(colors.white)
display.clear()
display.setCursorPos(1, 1)
display.write("System stopped.")
rednet.close()