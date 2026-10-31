-- Version: 1.1.2

-- ComputerCraft Cave Miner with Network Status Reporting
-- Core orchestrator that wires together smaller modules.

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
    facing = 0, -- 0=North, 1=East, 2=South, 3=West
    homePos = { x = 0, y = 0, z = 0 },
    totalOresMined = 0,
    currentBranch = 0,
    hasGPS = false,
    startY = 0,
    lastStatusTime = 0,
    miningY = 0,            -- Track the Y level where we're actually mining
    storageDirection = nil, -- Cache storage direction
    storageName = nil,      -- Cache storage name
}

-- Optional headless software update before starting
local function runAutoUpdates()
    -- Only attempt this on turtles with a shell environment
    if not turtle or not shell or not shell.run then
        return
    end

    print("")
    print("=== SOFTWARE UPDATE CHECK ===")

    local ok, err = pcall(function()
        -- Headless client that talks to the central update server
        -- This will auto-accept and install any newer versions of miner files.
        shell.run("turtle_updater", "--no-reboot")
    end)

    if not ok then
        print("Update check failed (continuing anyway): " .. tostring(err))
    else
        print("Software update check complete")
    end
end

-- Build modules on top of the shared context
local status = createStatus(ctx)
local movement = createMovement(ctx, status)
local inventory = createInventory(ctx, status, movement)
local mining = createMining(ctx, status, movement, inventory)

-- Whenever our position changes, report it to the central mined-area database
ctx.onPositionChanged = function(x, y, z)
    -- Best-effort, non-fatal logging
    pcall(function()
        rednet.broadcast({
            type = "BLOCK_MINED",
            x = x,
            y = y,
            z = z,
        }, MINED_PROTOCOL)
    end)
end

-- GPS helpers live here since they are small and only used at startup
local function getGPSPosition()
    print("Attempting GPS...")
    local x, y, z = gps.locate(5)

    if x then
        print("GPS found: " .. math.floor(x) .. "," .. math.floor(y) .. "," .. math.floor(z))
        return {
            x = math.floor(x),
            y = math.floor(y),
            z = math.floor(z),
        }
    else
        print("GPS not available")
        return nil
    end
end

local function setStartingPosition()
    print("")
    print("=== POSITION SETUP ===")

    local gpsPos = getGPSPosition()

    if gpsPos then
        ctx.position = gpsPos
        ctx.homePos = { x = gpsPos.x, y = gpsPos.y, z = gpsPos.z }
        ctx.startY = gpsPos.y
        ctx.hasGPS = true
        return true
    end

    print("No GPS - using relative positioning")
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
    return true
end

-- Public API
local Miner = {}

function Miner.run()
    -- Startup sequence
    runAutoUpdates()

    print("=== ComputerCraft Cave Miner ===")
    print("Turtle ID: " .. os.getComputerID())
    print("")

    -- Test network connection
    print("Testing network connection...")
    status.report("Initializing...")
    local netOk = status.testConnection()
    if netOk then
        print("Network OK!")
        status.report("Network connected")
    else
        print("No central monitor detected (continuing anyway)")
    end
    print("")

    -- Set position
    if not setStartingPosition() then
        print("Failed to set position!")
        return
    end

    -- Check for storage container BEFORE starting
    print("")
    print("=== STORAGE CHECK ===")
    status.report("Checking for storage container...")
    ctx.storageDirection, ctx.storageName = inventory.findStorage()

    if ctx.storageDirection then
        print("Storage found: " .. ctx.storageName .. " (" .. ctx.storageDirection .. ")")
        status.report("Storage: " .. ctx.storageName)
    else
        print("WARNING: No storage container detected!")
        print("Checked: down, forward, back, left, right")
        print("")
        print("The turtle needs a chest/barrel to store mined items.")
        print("Please place one adjacent to the turtle.")
        print("")
        write("Continue anyway? (y/n): ")
        local answer = read()
        if answer:lower() ~= "y" and answer:lower() ~= "yes" then
            print("Setup cancelled. Place storage and restart.")
            return
        end
    end

    -- Configure target Y level
    print("")
    print("=== MINING DEPTH CONFIGURATION ===")
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
    status.report("Checking fuel...")
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
                print("Current: " .. fuelLevel .. ", Required: " .. CONFIG.MIN_FUEL_TO_START)
                print("Please add more fuel and restart")
                status.report("ERROR: Insufficient fuel")
                return
            end
        else
            print("ERROR: No fuel found!")
            print("Current: " .. fuelLevel .. ", Required: " .. CONFIG.MIN_FUEL_TO_START)
            print("Please add fuel and restart")
            status.report("ERROR: Insufficient fuel")
            return
        end
    else
        print("Fuel Level: " .. fuelLevel)
        status.report("Fuel: " .. fuelLevel)
    end

    -- Show configuration
    print("")
    print("Configuration:")
    print("  Position: " .. (ctx.hasGPS and "GPS" or "Relative"))
    print("  Y-Level: " .. ctx.startY)
    print("  Pattern: " .. CONFIG.MINING_PATTERN)
    print("  Branch Length: " .. CONFIG.BRANCH_LENGTH)
    print("  Branch Spacing: " .. CONFIG.BRANCH_SPACING)
    if CONFIG.AUTO_DESCEND then
        print("  Auto-Descend: YES -> Y=" .. CONFIG.TARGET_Y_LEVEL)
    end
    print("")

    print("Starting in 3 seconds... (Ctrl+T to abort)")
    sleep(3)

    -- Start mining
    local ok, err = pcall(mining.mine)

    if not ok then
        print("=== CRITICAL ERROR ===")
        print(tostring(err))
        status.report("CRITICAL ERROR: " .. tostring(err))

        print("Attempting emergency return...")
        pcall(movement.returnHome)
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

