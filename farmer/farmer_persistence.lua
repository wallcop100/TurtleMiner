-- Version: 1.0.0
-- Farmer persistence: GPS detection, position save/restore on restart
-- Mirrors miner_persistence.lua patterns

local STATE_FILE = ".farmer_state"

local Persistence = {}

-- ============================================================
-- GPS DETECTION
-- ============================================================

-- Try to get GPS position. Returns x,y,z or nil if no GPS.
function Persistence.locateGPS(timeout)
    timeout = timeout or 3
    if not gps then return nil end
    local x, y, z = gps.locate(timeout)
    if x then
        return x, y, z
    end
    return nil
end

-- Determine facing using two GPS readings around a forward move.
-- Turtle moves forward one block, reads GPS delta, then moves back.
-- Returns facing (0=N,1=E,2=S,3=W) or nil if GPS unavailable/move failed.
function Persistence.detectFacingViaGPS()
    local x1, y1, z1 = Persistence.locateGPS(2)
    if not x1 then return nil end

    if not turtle.forward() then return nil end

    local x2, y2, z2 = Persistence.locateGPS(2)
    turtle.back()

    if not x2 then return nil end

    local dx = x2 - x1
    local dz = z2 - z1

    if     dz == -1 then return 0   -- North
    elseif dx ==  1 then return 1   -- East
    elseif dz ==  1 then return 2   -- South
    elseif dx == -1 then return 3   -- West
    end
    return nil
end

-- ============================================================
-- STATE PERSISTENCE
-- ============================================================

-- Save full turtle+farm state to disk.
-- sweepState (optional): { inProgress, row, col, goingEast }
function Persistence.save(ctx, sweepState)
    local file = fs.open(STATE_FILE, "w")
    if not file then
        print("WARNING: Cannot open state file for writing")
        return false
    end

    file.writeLine(textutils.serialize({
        -- Position & orientation
        position  = {
            x = ctx.position.x,
            y = ctx.position.y,
            z = ctx.position.z,
        },
        facing    = ctx.facing,
        homePos   = {
            x = ctx.homePos.x,
            y = ctx.homePos.y,
            z = ctx.homePos.z,
        },
        hasGPS    = ctx.hasGPS or false,

        -- Farm progress
        lastSeed      = ctx.lastSeed,
        farmCycles    = ctx.farmCycles    or 0,
        totalHarvested = ctx.totalHarvested or 0,
        currentRow    = ctx.currentRow    or 0,

        -- Mid-sweep resume data
        sweep = sweepState or { inProgress = false },

        timestamp = os.epoch("utc"),
    }))
    file.close()
    return true
end

-- Load saved state from disk. Returns table or nil.
function Persistence.load()
    if not fs.exists(STATE_FILE) then return nil end

    local file = fs.open(STATE_FILE, "r")
    if not file then return nil end

    local data = file.readAll()
    file.close()

    local ok, result = pcall(textutils.unserialize, data)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

-- Delete the state file (called after a clean sweep completes and
-- the turtle is safely home, so a restart begins fresh).
function Persistence.clear()
    if fs.exists(STATE_FILE) then
        fs.delete(STATE_FILE)
    end
end

-- Apply a loaded state snapshot back into ctx.
-- Does NOT restore sweep (caller handles that separately).
function Persistence.applyToCtx(ctx, state)
    ctx.position.x    = state.position.x
    ctx.position.y    = state.position.y
    ctx.position.z    = state.position.z
    ctx.facing        = state.facing
    ctx.homePos.x     = state.homePos.x
    ctx.homePos.y     = state.homePos.y
    ctx.homePos.z     = state.homePos.z
    ctx.hasGPS        = state.hasGPS or false
    ctx.lastSeed      = state.lastSeed
    ctx.farmCycles    = state.farmCycles    or 0
    ctx.totalHarvested = state.totalHarvested or 0
    ctx.currentRow    = state.currentRow    or 0
end

return Persistence
