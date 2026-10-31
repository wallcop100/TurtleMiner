-- Version: 2.0.8
-- Fixed: Coordinates now include turtle ID and GPS flag

local CONFIG = require("miner_config")
local statusLib = require("turtle_status")
local createStatus = require("miner_status")
local createMovement = require("miner_movement")
local createInventory = require("miner_inventory")
local createMining = require("miner_mining")

local MINED_PROTOCOL = "TURTLE_MINED_DB"

-- Shared miner context (state)
local ctx = {
    CONFIG = CONFIG,
    statusLib = statusLib,

    position = { x = 0, y = 0, z = 0 },
    facing = 0,
    homePos = { x = 0, y = 0, z = 0 },
    totalOresMined = 0,
    currentBranch = 0,
    hasGPS = false,
    startY = 0,
    lastStatusTime = 0,
    miningY = 0,
    storageDirection = nil,
    storageName = nil,
    focusedOre = "all",
    shouldReturnHome = false,
    commandCheckInterval = 2,
    lastCommandCheck = 0,
}

-- Command processor
local function processCommands()
    if not statusLib.hasPendingCommands() then
        return
    end

    local cmd = statusLib.getNextCommand()
    if not cmd then
        return
    end

    print("Processing command: " .. cmd.command)

    if cmd.command == "RETURN_HOME" then
        print("Remote command: Return to home")
        ctx.shouldReturnHome = true
        
    elseif cmd.command == "SET_TARGET_Y" and cmd.params and cmd.params.targetY then
        local newY = cmd.params.targetY
        print("Remote command: Set target Y to " .. newY)
        CONFIG.TARGET_Y_LEVEL = newY
        print("Target Y-level updated to: " .. newY)
        
    elseif cmd.command == "FOCUS_ORE" and cmd.params and cmd.params.oreType then
        local oreType = cmd.params.oreType
        print("Remote command: Focus on " .. oreType .. " ore")
        ctx.focusedOre = oreType
        print("Now focusing on: " .. oreType)
        
    elseif cmd.command == "RESUME_MINING" then
        print("Remote command: Resume mining")
        ctx.shouldReturnHome = false
        
    elseif cmd.command == "REQUEST_STATUS" then
        print("Remote command: Status requested")
    end
end

-- Check for commands periodically
local function checkCommands()
    local currentTime = os.epoch("utc") / 1000
    if currentTime - ctx.lastCommandCheck >= ctx.commandCheckInterval then
        processCommands()
        ctx.lastCommandCheck = currentTime
    end
end

        

-- Build modules
local status = createStatus(ctx)
local movement = createMovement(ctx, status)
local inventory = createInventory(ctx, status, movement)
local mining = createMining(ctx, status, movement, inventory)


-- Position change callback - NOW INCLUDES TURTLE ID AND GPS FLAG
ctx.onPositionChanged = function(x, y, z)
    pcall(function()
        rednet.broadcast({
            type = "BLOCK_MINED",
            turtleId = os.getComputerID(),  -- ADDED: Turtle ID
            hasGPS = ctx.hasGPS,             -- ADDED: GPS flag
            x = x,
            y = y,
            z = z,
        }, MINED_PROTOCOL)
    end)
end

-- GPS helpers
local function getGPSPosition()
    print("Attempting GPS...")
    status.report("GPS lookup...")
    local x, y, z = gps.locate(5)

    if x then
        print("GPS found: " .. math.floor(x) .. "," .. math.floor(y) .. "," .. math.floor(z))
        status.report("GPS locked")
        return {
            x = math.floor(x),
            y = math.floor(y),
            z = math.floor(z),
        }
    else
        print("GPS not available")
        status.report("No GPS signal")
        return nil
    end
end

local function setStartingPosition()
    print("")
    print("=== POSITION SETUP ===")
    status.report("Position setup...")

    -- First, try to recover position from central monitor
    local savedPos, savedFacing = statusLib.requestHomePosition()
    
    if savedPos and savedFacing then
        print("Recovered position from central monitor!")
        print("Home: (" .. savedPos.x .. ", " .. savedPos.y .. ", " .. savedPos.z .. ")")
        print("Facing: " .. savedFacing)
        
        ctx.position = { x = savedPos.x, y = savedPos.y, z = savedPos.z }
        ctx.homePos = { x = savedPos.x, y = savedPos.y, z = savedPos.z }
        ctx.facing = savedFacing
        ctx.startY = savedPos.y
        ctx.hasGPS = savedPos.hasGPS or false  -- Restore GPS flag
        
        status.report("Position recovered from backup")
        return true
    end

    -- If no saved position, try GPS
    local gpsPos = getGPSPosition()

    if gpsPos then
        ctx.position = gpsPos
        ctx.homePos = { x = gpsPos.x, y = gpsPos.y, z = gpsPos.z }
        ctx.startY = gpsPos.y
        ctx.hasGPS = true
        
        -- Save this position to central monitor WITH GPS flag
        local posToSave = {
            x = ctx.homePos.x,
            y = ctx.homePos.y,
            z = ctx.homePos.z,
            hasGPS = true
        }
        statusLib.reportHomePosition(posToSave, ctx.facing)
        
        return true
    end

    -- Manual position input as fallback
    print("No GPS - using relative positioning")
    status.report("Manual positioning")
    print("Enter Y-level (or press Enter for Y=64): ")
    local input = read()
    local yLevel = tonumber(input) or 64

    if yLevel < -64 or yLevel > 320 then
        yLevel = 64
    end

    ctx.position = { x = 0, y = yLevel, z = 0 }
    ctx.homePos = { x = 0, y = yLevel, z = 0 }
    ctx.startY = yLevel
    ctx.hasGPS = false

    print("Position set to: (0, " .. yLevel .. ", 0)")
    
    -- Save relative position WITH GPS flag = false
    local posToSave = {
        x = ctx.homePos.x,
        y = ctx.homePos.y,
        z = ctx.homePos.z,
        hasGPS = false
    }
    statusLib.reportHomePosition(posToSave, ctx.facing)
    
    return true
end

-- Public API
local Miner = {}

function Miner.run()
    print("=== ComputerCraft Cave Miner v2.0.1 ===")
    print("Turtle ID: " .. os.getComputerID())
    print("")
    status.report("Booting up...")

    -- Test network connection
    print("Testing network connection...")
    status.report("Network test...")
    local netOk = status.testConnection()
    if netOk then
        print("Network OK!")
        status.report("Network connected")
        -- There is a bug here somewhere, network connection is no longer maintained after shell.run for some reason
        shell.run("turtle_updater", "--no-reboot")
        status.report("Checked for Updates, Restablished Connection")
    else
        print("No central monitor detected (continuing anyway)")
        status.report("Offline mode")
    end
    print("")

    -- Start command listener
    print("Starting command listener...")
    parallel.waitForAny(
        function()
            statusLib.listenForCommands()
        end,
        function()
            sleep(1)
        end
    )

    -- Set position (with recovery support)
    if not setStartingPosition() then
        print("Failed to set position!")
        status.reportError("Position setup failed")
        return
    end

    -- Storage check
    print("")
    print("=== STORAGE CHECK ===")
    status.report("Storage check...")
    ctx.storageDirection, ctx.storageName = inventory.findStorage()

    if ctx.storageDirection then
        print("Storage found: " .. ctx.storageName .. " (" .. ctx.storageDirection .. ")")
        status.report("Storage: " .. ctx.storageName)
    else
        print("WARNING: No storage container detected!")
        status.reportWarning("No storage found")
        print("Checked: down, forward, back, left, right")
        print("")
        print("The turtle needs a chest/barrel to store mined items.")
        print("Please place one adjacent to the turtle.")
        print("")
        write("Continue anyway? (y/n): ")
        local answer = read()
        if answer:lower() ~= "y" and answer:lower() ~= "yes" then
            print("Setup cancelled. Place storage and restart.")
            status.report("Setup cancelled")
            return
        end
    end

    -- Depth configuration
    print("")
    print("=== MINING DEPTH CONFIGURATION ===")
    status.report("Depth config...")
    if CONFIG.AUTO_DESCEND then
        print("Current target Y-level: " .. CONFIG.TARGET_Y_LEVEL)
        print("(Optimal for diamonds: -59)")
        print("")
        write("Use default Y=" .. CONFIG.TARGET_Y_LEVEL .. "? (y/n): ")
        local answer = read()

        if answer:lower() == "n" or answer:lower() == "no" then
            write("Enter target Y-level (-64 to 320): ")
            local input = read()
            local targetY = tonumber(input)

            if targetY and targetY >= -64 and targetY <= 320 then
                CONFIG.TARGET_Y_LEVEL = targetY
                print("Target Y-level set to: " .. CONFIG.TARGET_Y_LEVEL)
                status.report("Target Y: " .. CONFIG.TARGET_Y_LEVEL)
            else
                print("Invalid input. Using default: " .. CONFIG.TARGET_Y_LEVEL)
            end
        end
    else
        print("Auto-descend is disabled")
        print("Turtle will mine at current Y-level: " .. ctx.position.y)
    end

    -- Fuel check
    print("")
    print("=== FUEL CHECK ===")
    status.report("Fuel check...")
    local fuelLevel = turtle.getFuelLevel()
    if fuelLevel == "unlimited" then
        print("Fuel: Unlimited")
        status.report("Fuel: Unlimited")
    elseif fuelLevel < CONFIG.MIN_FUEL_TO_START then
        print("Current fuel: " .. fuelLevel)
        print("Attempting to auto-refuel...")
        status.report("Auto-refueling...")

        if inventory.autoRefuel() then
            fuelLevel = turtle.getFuelLevel()
            print("Auto-refuel successful! New fuel: " .. fuelLevel)
            status.report("Refueled to " .. fuelLevel)

            if fuelLevel < CONFIG.MIN_FUEL_TO_START then
                print("ERROR: Still insufficient fuel!")
                status.reportError("Insufficient fuel")
                print("Current: " .. fuelLevel .. ", Required: " .. CONFIG.MIN_FUEL_TO_START)
                print("Please add more fuel and restart")
                return
            end
        else
            print("ERROR: No fuel found!")
            status.reportError("No fuel found")
            print("Current: " .. fuelLevel .. ", Required: " .. CONFIG.MIN_FUEL_TO_START)
            print("Please add fuel and restart")
            return
        end
    else
        print("Fuel Level: " .. fuelLevel)
        status.reportFuelStatus()
    end

    -- Show configuration
    print("")
    print("Configuration:")
    print("  Position: " .. (ctx.hasGPS and "GPS (Absolute)" or "Relative"))
    print("  Y-Level: " .. ctx.startY)
    print("  Pattern: " .. CONFIG.MINING_PATTERN)
    print("  Branch Length: " .. CONFIG.BRANCH_LENGTH)
    print("  Branch Spacing: " .. CONFIG.BRANCH_SPACING)
    if CONFIG.AUTO_DESCEND then
        print("  Auto-Descend: YES -> Y=" .. CONFIG.TARGET_Y_LEVEL)
    end
    print("  Remote Control: ENABLED")
    print("")

    print("Starting in 3 seconds... (Ctrl+T to abort)")
    status.report("Starting in 3...")
    sleep(1)
    status.report("Starting in 2...")
    sleep(1)
    status.report("Starting in 1...")
    sleep(1)

    -- Start mining with command processing
    local ok, err = pcall(function()
        parallel.waitForAny(
            mining.mine,
            function()
                -- Command processor loop
                while true do
                    checkCommands()
                    
                    -- Check if we should return home
                    if ctx.shouldReturnHome then
                        print("Remote return home command received!")
                        status.reportReturningHome("remote command")
                        ctx.shouldReturnHome = false
                        movement.returnHome()
                        inventory.emptyInventory()
                        shell.run("turtle_updater", "--no-reboot")
                    end
                    
                    sleep(1)
                end
            end
        )
    end)

    if not ok then
        print("=== CRITICAL ERROR ===")
        print(tostring(err))
        status.reportError(tostring(err))

        print("Attempting emergency return...")
        status.reportReturningHome("emergency")
        pcall(movement.returnHome)
        shell.run("turtle_updater", "--no-reboot")
    end

    print("")
    print("=== Mining Complete ===")
    print("Total ores: " .. ctx.totalOresMined)
    print("Total branches: " .. ctx.currentBranch)
    print("Final position: " .. ctx.position.x .. "," .. ctx.position.y .. "," .. ctx.position.z)
    print("Fuel remaining: " .. turtle.getFuelLevel())

    status.report("Shutdown complete. Ores: " .. ctx.totalOresMined)
end

return Miner