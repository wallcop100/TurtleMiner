-- Version: 1.1.0
-- Added: GPS position detection and persist/resume on restart
--
-- SETUP:
--   Turtle home:  (0, 1, -1)  — sitting on top of a chest, facing South (+Z)
--   Chest:        (0, 0, -1)  — directly below the turtle's home position
--   Farm area:    (0,0,0) to (FARM_WIDTH-1, 0, FARM_LENGTH-1)
--
-- RESTART BEHAVIOUR:
--   State is saved to disk after every move. On restart the turtle reads
--   its saved position (corrected by GPS if available), then navigates back
--   to wherever it was mid-sweep and carries on. If it was in the grow-wait
--   phase it starts a new sweep immediately.
--
-- GPS (optional):
--   Attach a wireless modem and place GPS satellites. If gps.locate()
--   succeeds at startup the turtle records true world coordinates. The
--   home position is set from GPS on the very first run and saved.
--   Facing is detected automatically by taking one test step.
--   Without GPS the turtle uses saved relative coordinates.
--
-- DEPENDENCIES (same folder or path):
--   turtle_status.lua      — base network library
--   farmer_status.lua      — farming status wrapper
--   farmer_persistence.lua — GPS detection + state save/restore

-- ============================================================
-- CONFIGURATION
-- ============================================================
-- ============================================================
-- CROP DATABASE
-- Maps block name -> { maxAge, seed }
-- maxAge: the age value at which the crop is fully grown
-- seed:   the item name used to replant
--
-- Add any modded crop here in the same format.
-- ============================================================
local CROP_DB = {
    -- Vanilla
    ["minecraft:wheat"]             = { maxAge = 7, seed = "minecraft:wheat_seeds" },
    ["minecraft:carrots"]           = { maxAge = 7, seed = "minecraft:carrot" },
    ["minecraft:potatoes"]          = { maxAge = 7, seed = "minecraft:potato" },
    ["minecraft:beetroots"]         = { maxAge = 3, seed = "minecraft:beetroot_seeds" },
    ["minecraft:nether_wart"]       = { maxAge = 3, seed = "minecraft:nether_wart" },
    -- Farmer's Delight (https://www.curseforge.com/minecraft/mc-mods/farmers-delight)
    ["farmersdelight:rice_panicles"] = { maxAge = 3, seed = "farmersdelight:rice_panicle" },
    ["farmersdelight:tomatoes"]     = { maxAge = 4, seed = "farmersdelight:tomato_seeds" },
    ["farmersdelight:onions"]       = { maxAge = 7, seed = "farmersdelight:onion" },
    ["farmersdelight:cabbages"]     = { maxAge = 7, seed = "farmersdelight:cabbage_seeds" },
    ["farmersdelight:potatoes"]     = { maxAge = 4, seed = "farmersdelight:potato" },
    ["farmersdelight:carrots"]      = { maxAge = 4, seed = "farmersdelight:carrot" },
    ["farmersdelight:sweet_berries"]= { maxAge = 3, seed = "minecraft:sweet_berries" },
    -- Pam's HarvestCraft / HarvestCraft 2 pattern (add as needed):
    -- ["harvestcraft2crops:corn"]  = { maxAge = 3, seed = "harvestcraft2food:cornitem" },
}

-- Build a reverse lookup: seed item -> crop block (for replanting detection)
local SEED_TO_CROP = {}
for blockName, data in pairs(CROP_DB) do
    SEED_TO_CROP[data.seed] = blockName
end

local CONFIG = {
    -- Farm dimensions
    FARM_WIDTH   = 18,   -- X axis (columns)
    FARM_LENGTH  = 9,   -- Z axis (rows)

    -- Timing
    GROW_WAIT    = 300,  -- seconds between sweeps (5 min default)
    STATUS_INTERVAL = 10,

    -- Fuel threshold; turtle refuels from chest before each sweep
    MIN_FUEL     = 200,
}

-- ============================================================
-- SHARED CONTEXT  (same pattern as miner ctx object)
-- ============================================================
local ctx = {
    CONFIG        = CONFIG,
    statusLib     = nil,   -- set after require
    position      = {x = 0, y = 1, z = -1},  -- home position (relative or GPS)
    facing        = 2,     -- 0=North(-Z) 1=East(+X) 2=South(+Z) 3=West(-X)
    homePos       = {x = 0, y = 1, z = -1},
    hasGPS        = false, -- true when GPS coordinates are confirmed
    lastStatusTime = 0,
    totalHarvested = 0,
    farmCycles    = 0,
    currentRow    = 0,
    lastSeed      = nil,   -- item name of the seed most recently planted/harvested
}

-- Tracks current sweep progress so it can be saved and restored on restart.
-- Updated by runFarmSweep() at every step; read by positionChanged() for saving.
local sweepState = { inProgress = false, row = 0, col = 0, goingEast = true }

-- ============================================================
-- LOAD DEPENDENCIES
-- ============================================================
local TurtleStatus   = require("turtle_status")
local createStatus   = require("farmer_status")
local Persistence    = require("farmer_persistence")

ctx.statusLib = TurtleStatus
local status  = createStatus(ctx)

-- ============================================================
-- MOVEMENT  (relative or GPS position tracking)
-- ============================================================
local movement = {}

local function positionChanged()
    status.autoReport()
    Persistence.save(ctx, sweepState)
end

function movement.forward()
    local ok = turtle.forward()
    if ok then
        if ctx.facing == 0 then ctx.position.z = ctx.position.z - 1
        elseif ctx.facing == 1 then ctx.position.x = ctx.position.x + 1
        elseif ctx.facing == 2 then ctx.position.z = ctx.position.z + 1
        elseif ctx.facing == 3 then ctx.position.x = ctx.position.x - 1
        end
        positionChanged()
    end
    return ok
end

function movement.back()
    local ok = turtle.back()
    if ok then
        if ctx.facing == 0 then ctx.position.z = ctx.position.z + 1
        elseif ctx.facing == 1 then ctx.position.x = ctx.position.x - 1
        elseif ctx.facing == 2 then ctx.position.z = ctx.position.z - 1
        elseif ctx.facing == 3 then ctx.position.x = ctx.position.x + 1
        end
        positionChanged()
    end
    return ok
end

function movement.up()
    local ok = turtle.up()
    if ok then ctx.position.y = ctx.position.y + 1; positionChanged() end
    return ok
end

function movement.down()
    local ok = turtle.down()
    if ok then ctx.position.y = ctx.position.y - 1; positionChanged() end
    return ok
end

function movement.turnRight()
    turtle.turnRight()
    ctx.facing = (ctx.facing + 1) % 4
end

function movement.turnLeft()
    turtle.turnLeft()
    ctx.facing = (ctx.facing - 1) % 4
end

-- Face a target cardinal direction (0-3)
function movement.faceDirection(dir)
    while ctx.facing ~= dir do
        movement.turnRight()
    end
end

-- Safe forward: dig any obstacle then move
function movement.safeForward()
    local attempts = 0
    while not movement.forward() do
        attempts = attempts + 1
        if attempts > 10 then
            status.reportError("Stuck moving forward")
            return false
        end
        turtle.dig()
        turtle.attack()
        sleep(0.4)
    end
    return true
end

-- Navigate to a target X/Z at the current Y (underground-safe: X first, then Z)
function movement.navigateTo(targetX, targetZ)
    -- Move in X first
    while ctx.position.x < targetX do
        movement.faceDirection(1)  -- East
        if not movement.safeForward() then return false end
    end
    while ctx.position.x > targetX do
        movement.faceDirection(3)  -- West
        if not movement.safeForward() then return false end
    end
    -- Then Z
    while ctx.position.z < targetZ do
        movement.faceDirection(2)  -- South
        if not movement.safeForward() then return false end
    end
    while ctx.position.z > targetZ do
        movement.faceDirection(0)  -- North
        if not movement.safeForward() then return false end
    end
    return true
end

-- Return to home position and face South
function movement.returnHome()
    status.reportReturningHome()
    -- Navigate to home X/Z (Y stays constant at 1 throughout farming)
    movement.navigateTo(ctx.homePos.x, ctx.homePos.z)
    -- Face South (original orientation)
    movement.faceDirection(2)
    status.reportEvent("Arrived", "home")
end

-- ============================================================
-- INVENTORY MANAGEMENT
--
-- Design: the chest is OUTPUT ONLY. Seeds replenish from harvest drops.
-- The turtle keeps any item that is a known seed (in CROP_DB or matches
-- lastSeed). Everything else goes into the chest.
-- ============================================================
local inventory = {}

-- Scan inventory and update ctx.lastSeed to whatever seed is currently held.
-- If lastSeed is already set, prefer that; otherwise pick the first known seed found.
function inventory.updateLastSeed()
    if ctx.lastSeed then
        -- Check we still have it
        for i = 1, 16 do
            local d = turtle.getItemDetail(i)
            if d and d.name == ctx.lastSeed then
                return  -- still present, keep it
            end
        end
    end
    -- lastSeed is gone or unset - find any known seed in inventory
    for i = 1, 16 do
        local d = turtle.getItemDetail(i)
        if d and SEED_TO_CROP[d.name] then
            ctx.lastSeed = d.name
            print("Seed type detected: " .. ctx.lastSeed)
            return
        end
    end
    ctx.lastSeed = nil  -- no seeds found
end

-- Count seeds of the current type (or all known seeds if lastSeed unset)
function inventory.seedCount()
    inventory.updateLastSeed()
    if not ctx.lastSeed then return 0 end
    local total = 0
    for i = 1, 16 do
        local d = turtle.getItemDetail(i)
        if d and d.name == ctx.lastSeed then
            total = total + turtle.getItemCount(i)
        end
    end
    return total
end

-- Select a slot containing the current seed type. Returns true if found.
function inventory.selectSeeds()
    inventory.updateLastSeed()
    if not ctx.lastSeed then return false end
    for i = 1, 16 do
        local d = turtle.getItemDetail(i)
        if d and d.name == ctx.lastSeed then
            turtle.select(i)
            return true
        end
    end
    return false
end

-- Refuel from the chest below. Pulls items one at a time into a scratch slot,
-- burns them as fuel, and drops back anything that isn't combustible.
-- Returns true if fuel is now >= MIN_FUEL (or unlimited).
function inventory.refuelFromChest()
    local fuel = turtle.getFuelLevel()
    if fuel == "unlimited" then return true end
    if fuel >= CONFIG.MIN_FUEL then return true end

    status.reportEvent("Refueling", "from chest (fuel: " .. tostring(fuel) .. ")")
    print("Refueling from chest...")

    local SCRATCH = 16  -- temporary slot for pulling items
    local attempts = 0
    while turtle.getFuelLevel() < CONFIG.MIN_FUEL and attempts < 64 do
        attempts = attempts + 1
        turtle.select(SCRATCH)
        if not turtle.suckDown(1) then
            break  -- chest empty or blocked
        end
        -- Try to burn it; if it's not fuel, put it back in the chest
        if not turtle.refuel(1) then
            turtle.dropDown()
        end
    end

    turtle.select(1)
    local newFuel = turtle.getFuelLevel()
    if newFuel ~= "unlimited" and newFuel < CONFIG.MIN_FUEL then
        status.reportWarning("Still low on fuel after refill: " .. newFuel)
        return false
    end
    print("Fuel OK: " .. tostring(turtle.getFuelLevel()))
    return true
end

-- Count total free slots
function inventory.freeSlots()
    local free = 0
    for i = 1, 16 do
        if turtle.getItemCount(i) == 0 then free = free + 1 end
    end
    return free
end

-- Dump everything into the chest below. No exceptions - seeds included.
-- Harvest drops always resupply seeds so there is no need to keep any back.
-- Turtle must be at home (above the chest) before calling this.
function inventory.dumpToChest()
    status.reportEvent("Dumping", "everything into chest")
    local dropped = 0
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            if turtle.dropDown() then
                dropped = dropped + 1
            else
                status.reportWarning("Cannot drop slot " .. i .. " - chest full?")
            end
        end
    end
    turtle.select(1)
    status.reportEvent("Dumped", dropped .. " stacks into chest")
end

-- Pull seeds from the chest below if running low.
-- Uses a scratch slot to inspect each item before accepting it, so mixed
-- ============================================================
-- CROP LOGIC
-- Works with any crop in CROP_DB. Detects crop type from inspectDown(),
-- replants with whatever seed was last harvested (ctx.lastSeed).
-- ============================================================
local farming = {}

-- Inspect the block below and return its CROP_DB entry (or nil if not a crop)
local function getCropBelow()
    local hasBlock, data = turtle.inspectDown()
    if not hasBlock or not data then return nil, nil end
    local cropData = CROP_DB[data.name]
    return cropData, data
end

-- Returns true if the block below is a fully grown crop in CROP_DB
function farming.isMature()
    local cropData, blockData = getCropBelow()
    if not cropData then return false end
    local age = blockData.state and blockData.state.age
    if age == nil then return false end
    return age >= cropData.maxAge
end

-- Returns true if the block below needs planting (air, farmland, or unknown block)
function farming.isEmpty()
    local cropData, blockData = getCropBelow()
    -- If there's no crop from CROP_DB here, it needs planting
    return cropData == nil
end

-- Harvest the crop below, update lastSeed from drops, then replant
function farming.harvestAndReplant()
    local _, blockData = getCropBelow()
    local cropName = blockData and blockData.name or "unknown"

    turtle.digDown()

    -- After digging, harvest drops land in our inventory.
    -- Scan for the seed this crop drops and update lastSeed.
    local cropInfo = CROP_DB[cropName]
    if cropInfo then
        ctx.lastSeed = cropInfo.seed
    end
    -- Also rescan inventory in case a different seed type appeared
    inventory.updateLastSeed()

    -- Replant with whatever seeds we have
    if inventory.selectSeeds() then
        local ok = turtle.placeDown()
        if not ok then
            status.reportWarning("placeDown failed at " ..
                string.format("(%d,0,%d)", ctx.position.x, ctx.position.z))
        end
    else
        status.reportWarning("Out of seeds - cannot replant at " ..
            string.format("(%d,0,%d)", ctx.position.x, ctx.position.z))
    end

    status.reportHarvest(cropName, 1)
    return true
end

-- Plant a seed on a bare farmland block
function farming.plant()
    if inventory.selectSeeds() then
        local ok = turtle.placeDown()
        if not ok then
            return false  -- not farmland, skip silently
        end
        return true
    end
    status.reportWarning("No seeds to plant")
    return false
end

-- Inspect the block below and act accordingly
function farming.checkAndAct()
    if farming.isMature() then
        farming.harvestAndReplant()
    elseif farming.isEmpty() then
        farming.plant()
    end
    -- Immature crop: leave it alone
end

-- ============================================================
-- FARM SWEEP  (snake/boustrophedon pattern)
-- ============================================================

-- Sweep the entire farm grid once, row by row.
-- resumePoint (optional): { row, col, goingEast } to resume a crashed sweep.
-- Row and col are relative to the farm origin (homePos.x, homePos.z).
local function runFarmSweep(resumePoint)
    local startRow = 0
    if resumePoint and resumePoint.inProgress then
        startRow = resumePoint.row or 0
        print(string.format("Resuming sweep from row %d", startRow))
        status.reportEvent("Resuming sweep", "from row " .. startRow)
    else
        status.reportEvent("Sweep start", string.format("%dx%d farm", CONFIG.FARM_WIDTH, CONFIG.FARM_LENGTH))
        print(string.format("Starting farm sweep #%d", ctx.farmCycles + 1))
    end

    -- Mark sweep as in-progress so a crash can be recovered
    sweepState.inProgress = true
    sweepState.row        = startRow
    sweepState.col        = 0
    sweepState.goingEast  = (startRow % 2 == 0)
    Persistence.save(ctx, sweepState)

    -- Refuel from chest before starting if needed
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" and fuel < CONFIG.MIN_FUEL then
        print("Low fuel (" .. tostring(fuel) .. ") - attempting refuel from chest")
        if not inventory.refuelFromChest() then
            status.reportWarning("Cannot refuel - skipping sweep")
            sweepState.inProgress = false
            Persistence.save(ctx, sweepState)
            return false
        end
    end

    -- Farm origin in world coordinates.
    -- The farm starts 1 block south (Z+1) of home, same X.
    -- This matches the default layout: home=(hx,1,hz), farm=(hx,0,hz+1).
    local originX = ctx.homePos.x
    local originZ = ctx.homePos.z + 1

    -- ---- Snake traversal ----
    -- Even rows: travel East (x: 0→WIDTH-1)
    -- Odd rows:  travel West (x: WIDTH-1→0)
    for row = startRow, CONFIG.FARM_LENGTH - 1 do
        ctx.currentRow = row + 1

        local goingEast = (row % 2 == 0)
        local startX    = goingEast and 0 or (CONFIG.FARM_WIDTH - 1)
        local endX      = goingEast and (CONFIG.FARM_WIDTH - 1) or 0
        local stepX     = goingEast and 1 or -1

        -- If resuming mid-row, start from saved col; otherwise from row start
        local startCol = startX
        if resumePoint and resumePoint.inProgress and row == startRow then
            startCol = resumePoint.col or startX
        end

        -- Navigate to the start column of this row
        if not movement.navigateTo(originX + startCol, originZ + row) then
            status.reportError("Cannot reach row " .. row)
            break
        end

        -- Face the correct X direction
        movement.faceDirection(goingEast and 1 or 3)

        -- Update sweep state for this row
        sweepState.row       = row
        sweepState.goingEast = goingEast
        Persistence.save(ctx, sweepState)

        -- Walk along the row
        local col = startCol
        while true do
            -- Save col position before acting so a crash here is recoverable
            sweepState.col = col
            Persistence.save(ctx, sweepState)

            farming.checkAndAct()
            status.autoReport()

            -- Inventory nearly full - go home, dump, come back
            if inventory.freeSlots() < 3 then
                status.reportEvent("Inventory", "nearly full - dumping mid-sweep")
                movement.returnHome()
                inventory.dumpToChest()
                inventory.refuelFromChest()
                -- Navigate back to where we were
                if not movement.navigateTo(originX + col, originZ + row) then
                    status.reportError("Cannot return to row after dump")
                    sweepState.inProgress = false
                    Persistence.save(ctx, sweepState)
                    return false
                end
                movement.faceDirection(goingEast and 1 or 3)
            end

            if col == endX then break end

            -- Step to next column
            if not movement.safeForward() then
                status.reportError("Stuck in row " .. row .. " at col=" .. col)
                break
            end
            col = col + stepX
        end

        status.reportRowComplete(row + 1, CONFIG.FARM_LENGTH)
    end

    -- ---- Return home ----
    movement.returnHome()
    inventory.dumpToChest()

    -- Mark sweep as complete BEFORE reportCycleComplete so the counter is right
    sweepState.inProgress = false
    Persistence.save(ctx, sweepState)

    status.reportCycleComplete()
    print(string.format("Sweep #%d complete. Total harvested: %d",
        ctx.farmCycles, ctx.totalHarvested))
    return true
end

-- ============================================================
-- STARTUP: GPS detection and state restore
-- ============================================================
print("=== Autonomous Farmer v1.1 ===")
local cropCount = 0; for _ in pairs(CROP_DB) do cropCount = cropCount + 1 end
print(string.format("Farm: %dx%d  Wait: %ds  Crops: %d types in DB",
    CONFIG.FARM_WIDTH, CONFIG.FARM_LENGTH, CONFIG.GROW_WAIT, cropCount))

-- ---- Try GPS ----
print("Checking for GPS...")
local gpsX, gpsY, gpsZ = Persistence.locateGPS(3)
if gpsX then
    ctx.hasGPS = true
    print(string.format("GPS found: (%d,%d,%d)", gpsX, gpsY, gpsZ))
else
    print("No GPS signal - using relative/saved coordinates")
end

-- ---- Load saved state ----
local savedState = Persistence.load()
local resumeSweep = false

if savedState then
    print(string.format("Saved state found (age: %ds)",
        math.floor((os.epoch("utc") - (savedState.timestamp or 0)) / 1000)))
    Persistence.applyToCtx(ctx, savedState)

    if gpsX then
        -- GPS overrides saved position with verified world coordinates
        ctx.position.x = gpsX
        ctx.position.y = gpsY
        ctx.position.z = gpsZ
        -- Detect facing via GPS (move one step, read delta, step back)
        print("Detecting facing via GPS...")
        local detectedFacing = Persistence.detectFacingViaGPS()
        if detectedFacing then
            ctx.facing = detectedFacing
            local dirs = {"North","East","South","West"}
            print("Facing: " .. dirs[ctx.facing + 1])
        else
            print("Could not detect facing - using saved value (" .. ctx.facing .. ")")
        end
    else
        print(string.format("Restored position: (%d,%d,%d) facing %d",
            ctx.position.x, ctx.position.y, ctx.position.z, ctx.facing))
    end

    -- Check if a sweep was interrupted
    if savedState.sweep and savedState.sweep.inProgress then
        resumeSweep = true
        print(string.format("Sweep was in progress at row %d, col %d - will resume",
            savedState.sweep.row, savedState.sweep.col))
    else
        print("No sweep in progress - will start fresh sweep")
    end
else
    -- First run - set home position
    if gpsX then
        ctx.position = { x = gpsX, y = gpsY, z = gpsZ }
        ctx.homePos  = { x = gpsX, y = gpsY, z = gpsZ }
        ctx.hasGPS   = true
        -- Detect facing on first GPS run
        local detectedFacing = Persistence.detectFacingViaGPS()
        if detectedFacing then
            ctx.facing = detectedFacing
        end
        print(string.format("GPS home set: (%d,%d,%d)", gpsX, gpsY, gpsZ))
    else
        print("First run - using default relative home (0,1,-1)")
    end
    Persistence.save(ctx, sweepState)
end

print(string.format("Home: (%d,%d,%d)  Chest below  Farm: (%d,%d,%d)→(%d,%d,%d)",
    ctx.homePos.x, ctx.homePos.y, ctx.homePos.z,
    ctx.homePos.x, ctx.homePos.y - 1, ctx.homePos.z + 1,
    ctx.homePos.x + CONFIG.FARM_WIDTH - 1, ctx.homePos.y - 1,
    ctx.homePos.z + CONFIG.FARM_LENGTH))

-- ---- Inventory & fuel ----
inventory.updateLastSeed()
inventory.refuelFromChest()
if ctx.lastSeed then
    print("Seed: " .. ctx.lastSeed .. " -> " .. (SEED_TO_CROP[ctx.lastSeed] or "?"))
end

status.report("Farmer started")

-- ============================================================
-- MAIN LOOP
-- ============================================================
while true do
    local ok = runFarmSweep(resumeSweep and savedState and savedState.sweep or nil)
    resumeSweep = false  -- only resume once; all subsequent sweeps start fresh
    savedState  = nil

    if not ok then
        status.reportWarning("Sweep failed - retrying in 30s")
        sleep(30)
    else
        -- Sweep complete and turtle is home - clear saved state so a crash
        -- during the wait period doesn't try to resume a finished sweep
        Persistence.clear()
        Persistence.save(ctx, { inProgress = false })

        status.reportWaiting(CONFIG.GROW_WAIT)
        print(string.format("Waiting %d seconds for crops to grow...", CONFIG.GROW_WAIT))

        local waited = 0
        while waited < CONFIG.GROW_WAIT do
            local chunk = math.min(CONFIG.STATUS_INTERVAL, CONFIG.GROW_WAIT - waited)
            sleep(chunk)
            waited = waited + chunk
            status.report(string.format("Waiting: %ds/%ds", waited, CONFIG.GROW_WAIT))
        end
    end
end