-- Turtle Software Update Client
-- Checks for and installs software updates from central server
-- AUTO-ACCEPT ENABLED

local UPDATE_PROTOCOL = "SOFTWARE_UPDATE"
local UPDATE_TIMEOUT = 10
local BACKUP_SUFFIX = ".backup"

local modem = peripheral.find("modem")

-- ================== MODEM ==================
local function initModem()
    if not modem then
        error("No wireless modem found")
    end
    rednet.open(peripheral.getName(modem))
end

-- ================== VERSION HANDLING ==================

-- Read version from file header: -- Version: x.y.z
local function readFileVersion(filename)
    if not fs.exists(filename) then return "unknown" end

    local f = fs.open(filename, "r")
    if not f then return "unknown" end

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
    return "unknown"
end

local function getInstalledVersion(filename)
    return readFileVersion(filename)
end

local function parseVersion(v)
    if v == "unknown" then return 0 end
    local a,b,c = v:match("(%d+)%.(%d+)%.(%d+)")
    if not a then return 0 end
    return tonumber(a)*10000 + tonumber(b)*100 + tonumber(c)
end

local function isNewer(newV, oldV)
    return parseVersion(newV) > parseVersion(oldV)
end

-- ================== NETWORK ==================

local function checkForUpdates()
    rednet.broadcast({
        type = "UPDATE_CHECK",
        turtleID = os.getComputerID(),
        timestamp = os.epoch("utc")
    }, UPDATE_PROTOCOL)

    local serverID, response = rednet.receive(UPDATE_PROTOCOL, UPDATE_TIMEOUT)
    if not serverID or response.type ~= "UPDATE_RESPONSE" then
        return nil
    end

    return serverID, response
end

local function downloadFile(serverID, filename)
    rednet.send(serverID, {
        type = "FILE_REQUEST",
        turtleID = os.getComputerID(),
        filename = filename,
        timestamp = os.epoch("utc")
    }, UPDATE_PROTOCOL)

    local senderID, response = rednet.receive(UPDATE_PROTOCOL, UPDATE_TIMEOUT)
    if senderID ~= serverID or response.type ~= "FILE_DATA" then
        return nil
    end

    return response.content, response.version
end

-- ================== FILE SAFETY ==================

local function backupFile(filename)
    if fs.exists(filename) then
        local b = filename .. BACKUP_SUFFIX
        if fs.exists(b) then fs.delete(b) end
        fs.copy(filename, b)
    end
end

local function restoreBackup(filename)
    local b = filename .. BACKUP_SUFFIX
    if fs.exists(b) then
        if fs.exists(filename) then fs.delete(filename) end
        fs.move(b, filename)
        return true
    end
    return false
end

local function installUpdate(filename, content)
    backupFile(filename)

    local f = fs.open(filename, "w")
    if not f then
        restoreBackup(filename)
        return false
    end

    f.write(content)
    f.close()

    if filename:match("%.lua$") then
        local ok = loadfile(filename)
        if not ok then
            restoreBackup(filename)
            return false
        end
    end

    local b = filename .. BACKUP_SUFFIX
    if fs.exists(b) then fs.delete(b) end

    return true
end

-- ================== MAIN ==================

local function performUpdate(targetFile)
    initModem()

    local serverID, response = checkForUpdates()
    if not serverID or not response.updates then
        print("No update server available")
        return false
    end

    if #response.updates == 0 then
        print("All software up to date")
        return false
    end

    local anyUpdated = false

    for _, update in ipairs(response.updates) do
        if not targetFile or update.filename == targetFile then
            local installed = getInstalledVersion(update.filename)
            if isNewer(update.version, installed) then
                print("Auto-updating:", update.filename, installed, "->", update.version)

                local content = downloadFile(serverID, update.filename)
                if content and installUpdate(update.filename, content) then
                    print("Updated:", update.filename)
                    anyUpdated = true
                else
                    print("Update failed:", update.filename)
                end
            end
        end
    end

    return anyUpdated
end

-- ================== ENTRY ==================

if not turtle then
    print("Must be run on a turtle")
    return
end

local args = {...}
local targetFile = nil
local noReboot = false

for _, arg in ipairs(args) do
    if arg == "--no-reboot" or arg == "no-reboot" or arg == "noreboot" then
        noReboot = true
    elseif not targetFile then
        targetFile = arg
    end
end

if targetFile and not targetFile:match("%.lua$") then
    targetFile = targetFile .. ".lua"
end

local updated = performUpdate(targetFile)
rednet.close()

if not noReboot then
    if updated then
        print("Updates installed. Rebooting...")
    else
        print("No updates installed. Rebooting anyway...")
    end
    sleep(1)
    os.reboot()
end
