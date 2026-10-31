-- Version: 1.0.0
-- Local persistence for turtle state and path tracking

local POSITION_FILE = ".turtle_position"
local SETTINGS_FILE = ".turtle_settings"
local PATH_FILE = ".turtle_path"

local Persistence = {}

-- Save current position and facing locally
-- extra (optional): table with additional state e.g. { miningY, currentBranch }
function Persistence.savePosition(position, facing, homePos, hasGPS, startY, extra)
    local file = fs.open(POSITION_FILE, "w")
    if not file then
        return false
    end

    file.writeLine(textutils.serialize({
        position      = position,
        facing        = facing,
        homePos       = homePos,
        hasGPS        = hasGPS,
        startY        = startY,
        miningY       = extra and extra.miningY or startY,
        currentBranch = extra and extra.currentBranch or 0,
        timestamp     = os.epoch("utc")
    }))
    file.close()
    return true
end

-- Load saved position
function Persistence.loadPosition()
    if not fs.exists(POSITION_FILE) then
        return nil
    end
    
    local file = fs.open(POSITION_FILE, "r")
    if not file then
        return nil
    end
    
    local data = file.readAll()
    file.close()
    
    local success, result = pcall(textutils.unserialize, data)
    if success and result then
        return result
    end
    return nil
end

-- Save last used settings
function Persistence.saveSettings(settings)
    local file = fs.open(SETTINGS_FILE, "w")
    if not file then
        return false
    end
    
    file.writeLine(textutils.serialize({
        targetY       = settings.targetY,
        pattern       = settings.pattern,
        branchLength  = settings.branchLength,
        branchSpacing = settings.branchSpacing,
        autoDescend   = settings.autoDescend,
        focusedOre    = settings.focusedOre,
        veinMining    = settings.veinMining,
        timestamp     = os.epoch("utc")
    }))
    file.close()
    return true
end

-- Load last used settings
function Persistence.loadSettings()
    if not fs.exists(SETTINGS_FILE) then
        return nil
    end
    
    local file = fs.open(SETTINGS_FILE, "r")
    if not file then
        return nil
    end
    
    local data = file.readAll()
    file.close()
    
    local success, result = pcall(textutils.unserialize, data)
    if success and result then
        return result
    end
    return nil
end

-- Track path as turtle moves (for recovery)
local pathLog = {}
local MAX_PATH_SIZE = 1000

function Persistence.addToPath(moveType, position)
    table.insert(pathLog, {
        type = moveType,  -- "forward", "back", "up", "down", "turnRight", "turnLeft"
        pos = {x = position.x, y = position.y, z = position.z},
        timestamp = os.epoch("utc")
    })
    
    -- Keep path size manageable
    if #pathLog > MAX_PATH_SIZE then
        table.remove(pathLog, 1)
    end
end

function Persistence.savePath()
    local file = fs.open(PATH_FILE, "w")
    if not file then
        return false
    end
    
    file.writeLine(textutils.serialize(pathLog))
    file.close()
    return true
end

function Persistence.loadPath()
    if not fs.exists(PATH_FILE) then
        return {}
    end
    
    local file = fs.open(PATH_FILE, "r")
    if not file then
        return {}
    end
    
    local data = file.readAll()
    file.close()
    
    local success, result = pcall(textutils.unserialize, data)
    if success and result then
        return result
    end
    return {}
end

function Persistence.clearPath()
    pathLog = {}
    if fs.exists(PATH_FILE) then
        fs.delete(PATH_FILE)
    end
end

function Persistence.clearAll()
    if fs.exists(POSITION_FILE) then
        fs.delete(POSITION_FILE)
    end
    if fs.exists(PATH_FILE) then
        fs.delete(PATH_FILE)
    end
    -- Keep settings file
end

return Persistence
