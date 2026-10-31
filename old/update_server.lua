-- Central Update Server
-- Hosts software updates for turtles

local UPDATE_PROTOCOL = "SOFTWARE_UPDATE"
local SOFTWARE_DIR = "/updates/"  -- Directory containing update files

-- Software catalog with versions and descriptions
-- Populated dynamically from files in SOFTWARE_DIR
local SOFTWARE_CATALOG = {}

-- Optional human-readable descriptions keyed by filename
local SOFTWARE_DESCRIPTIONS = {
    ["turtle_miner_network.lua"] = "Network-enabled mining script",
    ["turtle_status.lua"] = "Status reporting library",
    ["miner_core.lua"] = "Core miner orchestrator",
    ["miner_status.lua"] = "Miner network/status module",
    ["miner_movement.lua"] = "Miner movement/navigation helpers",
    ["miner_inventory.lua"] = "Miner inventory and fuel handling",
    ["miner_mining.lua"] = "Miner ore detection and branch mining logic",
}

-- Track connected turtles and their versions
local turtleRegistry = {}

local modem = peripheral.find("modem")

-- Initialize modem
local function initModem()
    if not modem then
        error("No wireless modem found! Please attach a wireless modem.")
    end
    
    rednet.open(peripheral.getName(modem))
    print("Update server started on channel: " .. UPDATE_PROTOCOL)
    return true
end

-- Load file content
local function loadFile(filename)
    local filepath = SOFTWARE_DIR .. filename
    
    if not fs.exists(filepath) then
        print("ERROR: File not found: " .. filepath)
        return nil
    end
    
    local file = fs.open(filepath, "r")
    if not file then
        print("ERROR: Could not open file: " .. filepath)
        return nil
    end
    
    local content = file.readAll()
    file.close()
    
    return content
end

-- Read version from file header: -- Version: x.y.z
local function readFileVersion(filepath)
    if not fs.exists(filepath) then return "0.0.0" end

    local f = fs.open(filepath, "r")
    if not f then return "0.0.0" end

    for _ = 1, 5 do
        local line = f.readLine()
        if not line then break end
        local v = line:match("[Vv]ersion:%s*(%d+%.%d+%.%d+)")
        if v then
            f.close()
            return v
        end
    end

    f.close()
    return "0.0.0"
end

local function parseVersion(v)
    if not v or v == "unknown" then return 0 end
    local a, b, c = v:match("(%d+)%.(%d+)%.(%d+)")
    if not a then return 0 end
    return tonumber(a) * 10000 + tonumber(b) * 100 + tonumber(c)
end

-- Check which updates a turtle needs
local function checkUpdates(turtleID, installedVersions)
    local updates = {}
    installedVersions = installedVersions or {}

    local hasInstalledInfo = next(installedVersions) ~= nil

    for filename, catalogInfo in pairs(SOFTWARE_CATALOG) do
        local availableVersion = catalogInfo.version or "0.0.0"
        local shouldAdd = false

        if hasInstalledInfo then
            local installedVersion = installedVersions[filename] or "0.0.0"
            if parseVersion(availableVersion) > parseVersion(installedVersion) then
                shouldAdd = true
            end
        else
            -- Client will re-check versions; advertise everything
            shouldAdd = true
        end

        if shouldAdd then
            table.insert(updates, {
                filename = filename,
                version = availableVersion,
                description = catalogInfo.description
            })
        end
    end
    
    -- Update registry
    turtleRegistry[turtleID] = {
        lastSeen = os.epoch("utc"),
        installedVersions = installedVersions,
        updatesAvailable = #updates
    }
    
    return updates
end

-- Handle update check request
local function handleUpdateCheck(senderID, message)
    print("Update check from Turtle #" .. senderID)
    
    local installedVersions = message.installedVersions or {}
    local updates = checkUpdates(senderID, installedVersions)
    
    local response = {
        type = "UPDATE_RESPONSE",
        serverID = os.getComputerID(),
        updates = updates,
        timestamp = os.epoch("utc")
    }
    
    rednet.send(senderID, response, UPDATE_PROTOCOL)
    
    if #updates > 0 then
        print("  " .. #updates .. " update(s) available")
        for _, update in ipairs(updates) do
            print("    - " .. update.filename .. " v" .. update.version)
        end
    else
        print("  All software up to date")
    end
end

-- Handle file download request
local function handleFileRequest(senderID, message)
    local filename = message.filename
    
    print("File request from Turtle #" .. senderID .. ": " .. filename)
    
    -- Verify file is in catalog
    if not SOFTWARE_CATALOG[filename] then
        print("  ERROR: File not in catalog")
        rednet.send(senderID, {
            type = "FILE_ERROR",
            error = "File not found in catalog: " .. filename
        }, UPDATE_PROTOCOL)
        return
    end
    
    -- Load file content
    local content = loadFile(filename)
    
    if not content then
        print("  ERROR: Could not load file")
        rednet.send(senderID, {
            type = "FILE_ERROR",
            error = "Could not load file from server"
        }, UPDATE_PROTOCOL)
        return
    end
    
    -- Send file to turtle
    local response = {
        type = "FILE_DATA",
        filename = filename,
        content = content,
        version = SOFTWARE_CATALOG[filename].version,
        size = #content,
        timestamp = os.epoch("utc")
    }
    
    rednet.send(senderID, response, UPDATE_PROTOCOL)
    print("  Sent file (" .. #content .. " bytes)")
end

-- Display server statistics
local function displayStats()
    term.clear()
    term.setCursorPos(1, 1)
    
    -- Header
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.clearLine()
    local title = " Software Update Server "
    term.setCursorPos(math.floor((term.getSize() - #title) / 2), 1)
    term.write(title)
    
    -- Server info
    term.setBackgroundColor(colors.black)
    term.setCursorPos(1, 2)
    term.setTextColor(colors.lightGray)
    local width, height = term.getSize()
    print("Server ID: " .. os.getComputerID())
    print("Protocol: " .. UPDATE_PROTOCOL)
    print(string.rep("-", width))
    
    -- Software catalog
    print("")
    term.setTextColor(colors.white)
    print("Available Software:")
    term.setTextColor(colors.lightGray)
    
    for filename, info in pairs(SOFTWARE_CATALOG) do
        print("  " .. filename .. " v" .. info.version)
        
        -- Check if file exists
        local filepath = SOFTWARE_DIR .. filename
        if fs.exists(filepath) then
            term.setTextColor(colors.lime)
            print("    Status: Ready")
        else
            term.setTextColor(colors.red)
            print("    Status: MISSING!")
        end
        term.setTextColor(colors.lightGray)
    end
    
    -- Turtle registry
    print("")
    term.setTextColor(colors.white)
    print("Registered Turtles: " .. #(function() local t={} for k in pairs(turtleRegistry) do table.insert(t,k) end return t end)())
    term.setTextColor(colors.lightGray)
    
    if next(turtleRegistry) then
        for turtleID, info in pairs(turtleRegistry) do
            local timeSince = (os.epoch("utc") - info.lastSeen) / 1000
            print("  Turtle #" .. turtleID)
            print("    Last seen: " .. math.floor(timeSince) .. "s ago")
            
            if info.updatesAvailable > 0 then
                term.setTextColor(colors.yellow)
                print("    Updates: " .. info.updatesAvailable .. " available")
                term.setTextColor(colors.lightGray)
            else
                term.setTextColor(colors.lime)
                print("    Updates: Up to date")
                term.setTextColor(colors.lightGray)
            end
        end
    else
        print("  No turtles registered yet")
    end
    
    -- Footer
    term.setCursorPos(1, height)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.clearLine()
    term.write(" Press 'Q' to quit | 'R' to reload catalog | 'C' to clear registry ")
    term.setBackgroundColor(colors.black)
end

-- Reload software catalog from files
local function reloadCatalog()
    print("Reloading software catalog...")
    
    -- Ensure updates directory exists
    if not fs.exists(SOFTWARE_DIR) then
        fs.makeDir(SOFTWARE_DIR)
        print("Created updates directory: " .. SOFTWARE_DIR)
    end
    
    -- Reset catalog and scan directory for .lua files
    SOFTWARE_CATALOG = {}
    local files = fs.list(SOFTWARE_DIR)
    local foundFiles = 0
    
    for _, filename in ipairs(files) do
        if filename:match("%.lua$") then
            local filepath = SOFTWARE_DIR .. filename
            local version = readFileVersion(filepath)
            local description = SOFTWARE_DESCRIPTIONS[filename] or "Auto-discovered update package"
            
            SOFTWARE_CATALOG[filename] = {
                version = version,
                description = description
            }
            
            foundFiles = foundFiles + 1
            print("  Found: " .. filename .. " v" .. version)
        end
    end
    
    if foundFiles == 0 then
        print("No .lua files found in " .. SOFTWARE_DIR)
    end
    
    print("Catalog reload complete (" .. foundFiles .. " file(s))")
    sleep(2)
end

-- Listen for requests
local function listenForRequests()
    while true do
        local senderID, message, protocol = rednet.receive(UPDATE_PROTOCOL, 1)
        
        if senderID and protocol == UPDATE_PROTOCOL and type(message) == "table" then
            local success, err = pcall(function()
                if message.type == "UPDATE_CHECK" then
                    handleUpdateCheck(senderID, message)
                elseif message.type == "FILE_REQUEST" then
                    handleFileRequest(senderID, message)
                end
            end)
            
            if not success then
                print("ERROR handling request: " .. tostring(err))
            end
        end
    end
end

-- Update display periodically
local function updateDisplay()
    while true do
        displayStats()
        sleep(2)
    end
end

-- Handle keyboard input
local function handleInput()
    while true do
        local event, key = os.pullEvent("key")
        
        if key == keys.q then
            return true  -- Quit
        elseif key == keys.r then
            reloadCatalog()
        elseif key == keys.c then
            turtleRegistry = {}
            print("Turtle registry cleared")
            sleep(1)
        end
    end
end

-- Main server loop
local function main()
    print("=== Software Update Server ===")
    print("Initializing...")
    
    -- Initialize modem
    local success, err = pcall(initModem)
    if not success then
        printError("ERROR: " .. tostring(err))
        return
    end
    
    -- Create updates directory if needed
    if not fs.exists(SOFTWARE_DIR) then
        fs.makeDir(SOFTWARE_DIR)
        print("Created updates directory: " .. SOFTWARE_DIR)
    end
    
    -- Build software catalog dynamically from files
    print("Scanning updates directory for software...")
    reloadCatalog()
    
    print("")
    print("Server ready! Starting GUI...")
    sleep(1)
    
    -- Display initial stats
    displayStats()
    
    -- Run server tasks in parallel
    parallel.waitForAny(
        listenForRequests,
        updateDisplay,
        handleInput
    )
    
    -- Cleanup
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    print("Update server stopped")
    rednet.close()
end

-- Run the server
main()
