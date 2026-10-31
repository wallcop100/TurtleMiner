-- Version: 3.2.1
-- Added: Auto-resume after 30 seconds with automatic home return

local CONFIG = require("miner_config")
local statusLib = require("turtle_status")
local persistence = require("miner_persistence")
local createStatus = require("miner_status")
local createMovement = require("miner_movement")
local createInventory = require("miner_inventory")
local createMining = require("miner_mining")

local MINED_PROTOCOL = "TURTLE_MINED_DB"

-- Shared miner context (state)
local ctx = {
    CONFIG = CONFIG,
    statusLib = statusLib,
    persistence = persistence,

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
    commandInterrupt = false,  -- NEW: Immediate interrupt flag
    commandCheckInterval = 0.5,  -- Check more frequently
    lastCommandCheck = 0,
}

-- Command processor with instant interrupts
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
        ctx.commandInterrupt = true  -- Immediate interrupt
        
    elseif cmd.command == "SET_TARGET_Y" and cmd.params and cmd.params.targetY then
        local newY = cmd.params.targetY
        print("Remote command: Set target Y to " .. newY)
        CONFIG.TARGET_Y_LEVEL = newY
        print("Target Y-level updated to: " .. newY)
        ctx.commandInterrupt = true  -- Interrupt to apply new settings

    elseif cmd.command == "SET_START_Y" and cmd.params and cmd.params.startY then
        local newStartY = cmd.params.startY
        print("Remote command: Set start Y to " .. newStartY)
        ctx.startY = newStartY
        ctx.homePos.y = newStartY
        -- Persist the change so it survives a restart
        persistence.savePosition(ctx.position, ctx.facing, ctx.homePos, ctx.hasGPS, ctx.startY, {
            miningY = ctx.miningY,
            currentBranch = ctx.currentBranch,
        })
        print("Start Y updated to: " .. newStartY)
        
    elseif cmd.command == "FOCUS_ORE" and cmd.params and cmd.params.oreType then
        local oreType = cmd.params.oreType
        print("Remote command: Focus on " .. oreType .. " ore")
        ctx.focusedOre = oreType
        print("Now focusing on: " .. oreType)
        
    elseif cmd.command == "RESUME_MINING" then
        print("Remote command: Resume mining")
        ctx.shouldReturnHome = false
        ctx.commandInterrupt = false
        
    elseif cmd.command == "REQUEST_STATUS" then
        print("Remote command: Status requested")
        -- Force immediate status update
        local status = require("miner_status")
        status.report("Status requested")
    end
end

-- Check for commands rapidly during mining operations
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
-- Also saves position to disk on every move so crashes don't lose location
local positionSaveCounter = 0
ctx.onPositionChanged = function(x, y, z)
    -- Broadcast to central monitor
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

    -- Save position to disk every move so restarts resume from the correct spot
    -- Using pcall so a disk write failure never crashes the miner
    positionSaveCounter = positionSaveCounter + 1
    pcall(function()
        persistence.savePosition(
            ctx.position,
            ctx.facing,
            ctx.homePos,
            ctx.hasGPS,
            ctx.startY,
            {
                miningY      = ctx.miningY,
                currentBranch = ctx.currentBranch,
            }
        )
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

local function calibrateFacingFromGPS()
    local x1, y1, z1 = gps.locate(5)
    if not x1 then return end

    if not turtle.forward() then
        status.reportEvent("Facing calibration", "blocked, cannot determine facing")
        return
    end

    local x2, _, z2 = gps.locate(5)
    turtle.back()  -- raw, no position tracking

    -- Re-anchor from GPS so any tracking drift during probe is wiped
    ctx.position = { x = math.floor(x1), y = math.floor(y1), z = math.floor(z1) }

    local dx = math.floor(x2) - math.floor(x1)
    local dz = math.floor(z2) - math.floor(z1)
    if     dz == -1 then ctx.facing = 0
    elseif dx ==  1 then ctx.facing = 1
    elseif dz ==  1 then ctx.facing = 2
    elseif dx == -1 then ctx.facing = 3
    end

    status.reportEvent("Facing calibrated", ctx.facing)
end

local function setStartingPosition()
    print("")
    print("=== POSITION SETUP ===")
    status.report("Position setup...")

    -- First, try to load from local persistence (for server restarts)
    local savedState = persistence.loadPosition()
    if savedState and savedState.position then
        print("Found locally saved position from previous session!")
        print("Position: (" .. savedState.position.x .. ", " .. savedState.position.y .. ", " .. savedState.position.z .. ")")
        print("Facing: " .. savedState.facing)
        print("Home: (" .. savedState.homePos.x .. ", " .. savedState.homePos.y .. ", " .. savedState.homePos.z .. ")")
        print("")
        print("Auto-resuming in 30 seconds...")
        print("Press any key to configure manually, or wait to auto-resume")
        
        -- Countdown with heartbeat and key detection
        local userInput = false
        local countdown = 30
        
        local function countdownTimer()
            while countdown > 0 and not userInput do
                if countdown % 5 == 0 or countdown <= 5 then
                    print("Auto-resume in " .. countdown .. " seconds... (press any key to cancel)")
                    status.report("Auto-resume in " .. countdown .. "s")
                end
                sleep(1)
                countdown = countdown - 1
            end
        end
        
        local function keyListener()
            os.pullEvent("key")
            userInput = true
        end
        
        local function heartbeat()
            while countdown > 0 and not userInput do
                status.report("Auto-resume in " .. countdown .. "s")
                sleep(3)
            end
        end
        
        -- Run countdown with key detection and heartbeat
        parallel.waitForAny(countdownTimer, keyListener, heartbeat)
        
        if not userInput then
            -- Timeout - auto-resume
            print("")
            print("=== AUTO-RESUMING FROM SAVED POSITION ===")
            status.report("Auto-resume: restoring position")
            
            ctx.position = savedState.position
            ctx.homePos = savedState.homePos
            ctx.facing = savedState.facing
            ctx.hasGPS = savedState.hasGPS or false
            ctx.startY = savedState.homePos.y
            ctx.miningY = savedState.miningY or ctx.startY
            
            print("Position restored: (" .. ctx.position.x .. ", " .. ctx.position.y .. ", " .. ctx.position.z .. ")")
            print("Home: (" .. ctx.homePos.x .. ", " .. ctx.homePos.y .. ", " .. ctx.homePos.z .. ")")
            
            -- Report position to central monitor
            local posToSave = {
                x = ctx.homePos.x,
                y = ctx.homePos.y,
                z = ctx.homePos.z,
                hasGPS = ctx.hasGPS
            }
            statusLib.reportHomePosition(posToSave, ctx.facing)
            
            -- Calculate distance from home
            local distanceHome = math.abs(ctx.position.x - ctx.homePos.x) +
                                 math.abs(ctx.position.y - ctx.homePos.y) +
                                 math.abs(ctx.position.z - ctx.homePos.z)
            
            if distanceHome > 0 then
                print("")
                print("Current position is " .. distanceHome .. " blocks from home")
                print("Returning to home position for safety...")
                status.report("Returning home after restart")
                
                -- Return home
                if not movement.returnHome() then
                    print("ERROR: Could not return home!")
                    status.reportError("Failed to return home after restart")
                    print("Position may be incorrect. Manual intervention required.")
                    print("Press Enter to continue anyway, or Ctrl+T to abort...")
                    
                    parallel.waitForAny(
                        function() read() end,
                        function()
                            while true do
                                status.report("Waiting for user (navigation failed)")
                                sleep(3)
                            end
                        end
                    )
                else
                    print("Successfully returned home!")
                    status.report("Home position confirmed")
                end
            else
                print("Already at home position")
                status.report("Position confirmed at home")
            end
            
            return true
        else
            -- User pressed key - ask for input
            print("")
            print("Auto-resume cancelled by user")
            write("Use saved position anyway? (y/n): ")
            local answer
            parallel.waitForAny(
                function()
                    answer = read()
                end,
                function()
                    while true do
                        status.report("Waiting for user input...")
                        sleep(3)
                    end
                end
            )
            
            if answer:lower() == "y" or answer:lower() == "yes" then
                ctx.position = savedState.position
                ctx.homePos = savedState.homePos
                ctx.facing = savedState.facing
                ctx.hasGPS = savedState.hasGPS or false
                ctx.startY = savedState.homePos.y
                ctx.miningY = savedState.miningY or ctx.startY
                
                print("Position restored from local save")
                status.report("Position recovered locally")
                
                -- Report position to central monitor
                local posToSave = {
                    x = ctx.homePos.x,
                    y = ctx.homePos.y,
                    z = ctx.homePos.z,
                    hasGPS = ctx.hasGPS
                }
                statusLib.reportHomePosition(posToSave, ctx.facing)
                
                return true
            else
                print("Clearing saved position...")
                persistence.clearAll()
                statusLib.clearHomePosition()  -- Clear central monitor too
            end
        end
    end

    -- Try to recover position from central monitor
    local savedPos, savedFacing = statusLib.requestHomePosition()
    
    if savedPos and savedFacing then
        print("Recovered position from central monitor!")
        print("Home: (" .. savedPos.x .. ", " .. savedPos.y .. ", " .. savedPos.z .. ")")
        print("Facing: " .. savedFacing)
        
        ctx.position = { x = savedPos.x, y = savedPos.y, z = savedPos.z }
        ctx.homePos = { x = savedPos.x, y = savedPos.y, z = savedPos.z }
        ctx.facing = savedFacing
        ctx.startY = savedPos.y
        ctx.hasGPS = savedPos.hasGPS or false
        
        -- Save locally too
        persistence.savePosition(ctx.position, ctx.facing, ctx.homePos, ctx.hasGPS, ctx.startY)
        
        status.report("Position recovered from central")
        return true
    end

    -- If no saved position, try GPS
    local gpsPos = getGPSPosition()

    if gpsPos then
        ctx.position = gpsPos
        ctx.homePos = { x = gpsPos.x, y = gpsPos.y, z = gpsPos.z }
        ctx.startY = gpsPos.y
        ctx.hasGPS = true
        calibrateFacingFromGPS()
        
        -- Save this position both locally and to central monitor
        persistence.savePosition(ctx.position, ctx.facing, ctx.homePos, ctx.hasGPS, ctx.startY)
        
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
    
    -- Heartbeat during input
    local function heartbeat()
        while true do
            status.report("Waiting for user input...")
            sleep(3)
        end
    end
    
    print("Enter Y-level (or press Enter for Y=64): ")
    local input
    parallel.waitForAny(
        function()
            input = read()
        end,
        heartbeat
    )
    
    local yLevel = tonumber(input) or 64

    if yLevel < -64 or yLevel > 320 then
        yLevel = 64
    end

    ctx.position = { x = 0, y = yLevel, z = 0 }
    ctx.homePos = { x = 0, y = yLevel, z = 0 }
    ctx.startY = yLevel
    ctx.hasGPS = false

    print("Position set to: (0, " .. yLevel .. ", 0)")
    
    -- Save both locally and to central
    persistence.savePosition(ctx.position, ctx.facing, ctx.homePos, ctx.hasGPS, ctx.startY)
    
    local posToSave = {
        x = ctx.homePos.x,
        y = ctx.homePos.y,
        z = ctx.homePos.z,
        hasGPS = false
    }
    statusLib.reportHomePosition(posToSave, ctx.facing)
    
    return true
end

-- Configure mining settings with saved defaults
local function configureSettings()
    print("")
    print("=== MINING SETTINGS ===")
    status.report("Configuring settings...")
    
    -- Heartbeat function for user input
    local function heartbeat()
        while true do
            status.report("Waiting for user input...")
            sleep(3)
        end
    end
    
    -- Try to load saved settings
    local savedSettings = persistence.loadSettings()
    
    if savedSettings then
        print("Found saved settings from previous session:")
        print("  Target Y: " .. savedSettings.targetY)
        print("  Pattern: " .. savedSettings.pattern)
        print("  Branch Length: " .. savedSettings.branchLength)
        print("  Branch Spacing: " .. savedSettings.branchSpacing)
        print("  Focused Ore: " .. savedSettings.focusedOre)
        print("  Vein Mining: " .. (savedSettings.veinMining and "enabled" or "disabled"))
        print("")
        
        write("Use saved settings? (y/n): ")
        local answer
        parallel.waitForAny(
            function()
                answer = read()
            end,
            heartbeat
        )
        
        if answer:lower() == "y" or answer:lower() == "yes" then
            CONFIG.TARGET_Y_LEVEL = savedSettings.targetY
            CONFIG.MINING_PATTERN = savedSettings.pattern
            CONFIG.BRANCH_LENGTH = savedSettings.branchLength
            CONFIG.BRANCH_SPACING = savedSettings.branchSpacing
            CONFIG.AUTO_DESCEND = savedSettings.autoDescend
            CONFIG.MINE_ENTIRE_VEINS = savedSettings.veinMining ~= false  -- Default to true
            ctx.focusedOre = savedSettings.focusedOre or "all"
            print("Settings loaded!")
            return
        end
    end
    
    -- Configure new settings
    print("Configure mining settings:")
    print("")
    
    -- Start Y override
    print("Current start Y-level (home height): " .. ctx.startY)
    print("Override start Y? (press Enter to keep current)")
    write("> ")

    local startYInput
    parallel.waitForAny(
        function()
            startYInput = read()
        end,
        heartbeat
    )

    if startYInput ~= "" then
        local newStartY = tonumber(startYInput)
        if newStartY and newStartY >= -64 and newStartY <= 320 then
            ctx.startY = newStartY
            ctx.homePos.y = newStartY
            print("Start Y updated to: " .. ctx.startY)
        else
            print("Invalid input. Keeping current: " .. ctx.startY)
        end
    end

    -- Mining depth configuration
    if CONFIG.AUTO_DESCEND then
        print("Enter target Y-level (-64 to 320)")
        print("Optimal for diamonds: -59")
        print("Press Enter for default: " .. CONFIG.TARGET_Y_LEVEL)
        write("> ")
        
        local input
        parallel.waitForAny(
            function()
                input = read()
            end,
            heartbeat
        )
        
        if input ~= "" then
            local targetY = tonumber(input)
            if targetY and targetY >= -64 and targetY <= 320 then
                CONFIG.TARGET_Y_LEVEL = targetY
                print("Target Y-level set to: " .. CONFIG.TARGET_Y_LEVEL)
            else
                print("Invalid input. Using default: " .. CONFIG.TARGET_Y_LEVEL)
            end
        end
    end
    
    -- Ore focus configuration
    print("")
    print("Focus on specific ore? (optional)")
    print("Options: diamond, emerald, gold, iron, all")
    print("Press Enter for 'all'")
    write("> ")
    
    local oreInput
    parallel.waitForAny(
        function()
            oreInput = read()
        end,
        heartbeat
    )
    
    if oreInput ~= "" then
        local validOres = {diamond = true, emerald = true, gold = true, iron = true, all = true}
        if validOres[oreInput:lower()] then
            ctx.focusedOre = oreInput:lower()
            print("Focusing on: " .. ctx.focusedOre)
        else
            print("Invalid ore type. Using 'all'")
            ctx.focusedOre = "all"
        end
    else
        ctx.focusedOre = "all"
    end
    
    -- Vein mining configuration
    print("")
    print("Mine entire ore veins when found?")
    print("(Finds and mines all connected ore blocks, then returns to path)")
    print("Recommended: yes")
    write("Enable vein mining? (y/n, default y): ")
    
    local veinInput
    parallel.waitForAny(
        function()
            veinInput = read()
        end,
        heartbeat
    )
    
    if veinInput:lower() == "n" or veinInput:lower() == "no" then
        CONFIG.MINE_ENTIRE_VEINS = false
        print("Vein mining disabled")
    else
        CONFIG.MINE_ENTIRE_VEINS = true
        print("Vein mining enabled")
    end
    
    -- Save settings for next time
    persistence.saveSettings({
        targetY = CONFIG.TARGET_Y_LEVEL,
        pattern = CONFIG.MINING_PATTERN,
        branchLength = CONFIG.BRANCH_LENGTH,
        branchSpacing = CONFIG.BRANCH_SPACING,
        autoDescend = CONFIG.AUTO_DESCEND,
        focusedOre = ctx.focusedOre,
        veinMining = CONFIG.MINE_ENTIRE_VEINS
    })
    
    print("Settings saved!")
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

    -- Configure settings
    configureSettings()

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
    print("  Focused Ore: " .. ctx.focusedOre)
    print("  Vein Mining: " .. (CONFIG.MINE_ENTIRE_VEINS and "ENABLED" or "disabled"))
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

    -- Start mining with rapid command processing
    local ok, err = pcall(function()
        parallel.waitForAny(
            mining.mine,
            function()
                -- Rapid command processor loop
                while true do
                    checkCommands()
                    
                    -- Check if we should return home
                    if ctx.shouldReturnHome then
                        print("Remote return home command received!")
                        status.reportReturningHome("remote command")
                        ctx.commandInterrupt = true  -- Signal immediate stop
                        
                        -- Wait for mining to stop
                        sleep(2)
                        
                        ctx.shouldReturnHome = false
                        ctx.commandInterrupt = false
                        
                        movement.returnHome()
                        inventory.emptyInventory()
                        persistence.savePath()  -- Save path after returning
                        shell.run("turtle_updater", "--no-reboot")
                    end
                    
                    -- Check commands very frequently
                    sleep(0.1)
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
        persistence.savePath()  -- Save path before shutdown
        shell.run("turtle_updater", "--no-reboot")
    end

    print("")
    print("=== Mining Complete ===")
    print("Total ores: " .. ctx.totalOresMined)
    print("Total branches: " .. ctx.currentBranch)
    print("Final position: " .. ctx.position.x .. "," .. ctx.position.y .. "," .. ctx.position.z)
    print("Fuel remaining: " .. turtle.getFuelLevel())

    persistence.savePath()  -- Final path save
    status.report("Shutdown complete. Ores: " .. ctx.totalOresMined)
end

return Miner