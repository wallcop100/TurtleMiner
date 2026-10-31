-- Version: 1.0.0
-- TurtleMiner navigation: journaled moves/turns, retrying dig/attack, goTo, crash recovery,
-- GPS sync and facing calibration.
--
-- Every move/turn: state.logIntent(op, fuelBefore) -> turtle op -> update st -> state.logDone.
-- A failed op is also closed with a "D" line (unchanged position), so only an op that was in
-- flight when the computer died leaves a dangling "I".
--
-- nav.init(st, opts) options (all optional):
--   opts.shouldAbort() -> bool   polled between retries (never before the first attempt)
--   opts.onMove(st)              after every successful move or turn
--   opts.save()                  persist st (default: state.save(st))
--   opts.cfg                     config table; uses STUCK_TIMEOUT (60) and SNAPSHOT_EVERY (100)
--   opts.onEvent(level, text)    recovery events ("world rollback", "GPS correction", ...)
--
-- Fields added to st by this module:
--   st.lost           string|nil  position/facing could not be recovered; recover() and goTo()
--                                 refuse while set. Main clears it on RESET_HOME.
--   st.facingUnknown  bool|nil    set while calibrateFacing() is probing; a crash during the
--                                 probe makes the next recover() calibrate again.

local state = require("state")

local nav = {}

local st = nil
local opts = {}
local movesSinceSave = 0

local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

local MOVE   = { f = "forward", b = "back", u = "up", d = "down" }
local DETECT = { f = "detect", u = "detectUp", d = "detectDown" }
local DIG    = { f = "dig", u = "digUp", d = "digDown" }
local ATTACK = { f = "attack", u = "attackUp", d = "attackDown" }

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

local function now()
    if os.epoch then return os.epoch("utc") / 1000 end
    return os.clock()
end

local function cfgVal(key, default)
    local c = opts.cfg
    if type(c) == "table" and type(c[key]) == "number" then return c[key] end
    return default
end

local function fuel()
    return turtle.getFuelLevel()
end

local function save()
    if opts.save then return opts.save() end
    return state.save(st)
end

local function event(level, text)
    if opts.onEvent then pcall(opts.onEvent, level, text) end
end

local function copyPos(p)
    return { x = p.x, y = p.y, z = p.z }
end

local function samePos(a, b)
    return a.x == b.x and a.y == b.y and a.z == b.z
end

local function posStr(p)
    return p.x .. "," .. p.y .. "," .. p.z
end

-- position after op from (p, facing)
local function applyOp(p, facing, op)
    local q = copyPos(p)
    local f = facing
    if op == "f" then
        q.x = q.x + DX[f]; q.z = q.z + DZ[f]
    elseif op == "b" then
        q.x = q.x - DX[f]; q.z = q.z - DZ[f]
    elseif op == "u" then
        q.y = q.y + 1
    elseif op == "d" then
        q.y = q.y - 1
    elseif op == "l" then
        f = (f + 3) % 4
    elseif op == "r" then
        f = (f + 1) % 4
    end
    return q, f
end

local function afterSuccess()
    movesSinceSave = movesSinceSave + 1
    if movesSinceSave >= cfgVal("SNAPSHOT_EVERY", 100) then
        movesSinceSave = 0
        save()
    end
    if opts.onMove then opts.onMove(st) end
end

-- One journaled turtle op. Returns ok, err from the turtle call.
local function step(op)
    local before = fuel()
    state.logIntent(op, before)
    local ok, err
    if op == "l" then
        ok, err = turtle.turnLeft()
    elseif op == "r" then
        ok, err = turtle.turnRight()
    else
        ok, err = turtle[MOVE[op]]()
    end
    if ok then
        st.pos, st.facing = applyOp(st.pos, st.facing, op)
    end
    state.logDone(st, fuel())   -- on failure this closes the intent with the unchanged pos
    if ok then afterSuccess() end
    return ok, err
end

local function hasFuel()
    local f = fuel()
    return f == "unlimited" or f >= 1
end

----------------------------------------------------------------------------
-- init / movement
----------------------------------------------------------------------------

function nav.init(stIn, o)
    st = stIn
    opts = o or {}
    movesSinceSave = 0
end

-- op: "f" | "u" | "d"
local function moveDig(op, dig)
    if dig == nil then dig = true end
    local timeout = cfgVal("STUCK_TIMEOUT", 60)
    local lastProgress = now()
    local first = true
    while true do
        if not first then
            if opts.shouldAbort and opts.shouldAbort() then return false, "abort" end
            if now() - lastProgress > timeout then return false, "timeout" end
        end
        first = false
        if not hasFuel() then return false, "no_fuel" end

        local progressed = false
        if turtle[DETECT[op]]() then
            if not dig then return false, "blocked" end
            local ok, err = turtle[DIG[op]]()
            if ok then
                progressed = true
            elseif type(err) == "string" and string.find(err, "Unbreakable") then
                return false, "unbreakable"
            end
        end
        if not turtle[DETECT[op]]() then
            local ok, err = step(op)
            if ok then return true end
            if type(err) == "string" and string.find(string.lower(err), "fuel") then
                return false, "no_fuel"
            end
            -- entity in the way (mob, falling gravel, player)
            if turtle[ATTACK[op]]() then progressed = true end
        end
        if progressed then
            lastProgress = now()
        else
            sleep(0.2)
        end
    end
end

function nav.forward(dig) return moveDig("f", dig) end
function nav.up(dig) return moveDig("u", dig) end
function nav.down(dig) return moveDig("d", dig) end

function nav.turnLeft()
    local ok, err = step("l")
    if not ok then return false, err or "turn failed" end
    return true
end

function nav.turnRight()
    local ok, err = step("r")
    if not ok then return false, err or "turn failed" end
    return true
end

function nav.face(dir)
    dir = math.floor(dir) % 4
    local diff = (dir - st.facing) % 4
    if diff == 1 then
        return nav.turnRight()
    elseif diff == 2 then
        local ok, err = nav.turnRight()
        if not ok then return false, err end
        return nav.turnRight()
    elseif diff == 3 then
        return nav.turnLeft()
    end
    return true
end

-- turtle.back without digging; if that fails, turn around and go forward (digging unless
-- dig == false), then turn back.
function nav.back(dig)
    if not hasFuel() then return false, "no_fuel" end
    local ok = step("b")
    if ok then return true end
    local f0 = st.facing
    local tok, terr = nav.face((f0 + 2) % 4)
    if not tok then return false, terr end
    local mok, merr = nav.forward(dig ~= false)
    local rok, rerr = nav.face(f0)
    if not mok then return false, merr end
    if not rok then return false, rerr end
    return true
end

----------------------------------------------------------------------------
-- goTo
----------------------------------------------------------------------------

function nav.dist(a, b)
    return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

function nav.fuelToHome(s)
    s = s or st
    return nav.dist(s.pos, s.home)
end

local function moveAxis(axis, target, dig)
    if axis == "y" then
        while st.pos.y < target.y do
            local ok, err = nav.up(dig)
            if not ok then return false, err end
        end
        while st.pos.y > target.y do
            local ok, err = nav.down(dig)
            if not ok then return false, err end
        end
        return true
    end
    local d
    if axis == "x" then d = target.x - st.pos.x else d = target.z - st.pos.z end
    if d == 0 then return true end
    local dir
    if axis == "x" then dir = (d > 0) and 1 or 3 else dir = (d > 0) and 2 or 0 end
    local ok, err = nav.face(dir)
    if not ok then return false, err end
    for _ = 1, math.abs(d) do
        ok, err = nav.forward(dig)
        if not ok then return false, err end
    end
    return true
end

local function runOrder(order, target, dig)
    for i = 1, #order do
        local ok, err = moveAxis(string.sub(order, i, i), target, dig)
        if not ok then return false, err end
    end
    return true
end

-- opts2.order ("xzy", "yxz", ...), opts2.dig (default true), opts2.facing (face at the end)
function nav.goTo(target, opts2)
    opts2 = opts2 or {}
    if st.lost then return false, "position unknown" end
    local tgt = { x = math.floor(target.x), y = math.floor(target.y), z = math.floor(target.z) }
    local dig = opts2.dig
    if dig == nil then dig = true end
    local order = opts2.order
    if type(order) ~= "string" or order == "" then
        if tgt.y > st.pos.y then order = "xzy" else order = "yxz" end
    end
    local ok, err = runOrder(order, tgt, dig)
    if not ok and err ~= "abort" and err ~= "no_fuel" then
        ok, err = runOrder(string.reverse(order), tgt, dig)
    end
    if not ok then return false, err end
    if not samePos(st.pos, tgt) then return false, "not at target" end
    if opts2.facing ~= nil then return nav.face(opts2.facing) end
    return true
end

----------------------------------------------------------------------------
-- GPS
----------------------------------------------------------------------------

function nav.gpsLocate()
    if not st or not st.gps or not gps or not gps.locate then return nil end
    local ok, x, y, z = pcall(gps.locate, 2)
    if not ok or not x or not y or not z then return nil end
    -- round, not floor: guards against 12.9999 style float noise
    return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

local function facingFromDelta(dx, dz)
    if dx == 1 and dz == 0 then return 1 end
    if dx == -1 and dz == 0 then return 3 end
    if dx == 0 and dz == -1 then return 0 end
    if dx == 0 and dz == 1 then return 2 end
    return nil
end

-- Moves one block (forward, else back, else up+forward), compares GPS fixes, returns to the
-- start. Never digs (the turtle may be next to its chest). Never guesses.
function nav.calibrateFacing()
    if not st.gps then return false, "cannot calibrate facing (no GPS mode)" end
    local p0 = nav.gpsLocate()
    if not p0 then return false, "cannot calibrate facing (no GPS signal)" end
    st.pos = p0
    st.facingUnknown = true
    save()

    local function finish(f)
        st.facing = f
        st.facingUnknown = nil
        local p = nav.gpsLocate()
        if p then st.pos = p end
        save()
        return true
    end

    local function needFuel(n)
        local f = fuel()
        return f == "unlimited" or f >= n
    end

    -- forward probe
    if needFuel(2) and not turtle.detect() and step("f") then
        local p1 = nav.gpsLocate()
        local f = p1 and facingFromDelta(p1.x - p0.x, p1.z - p0.z)
        if f then st.facing = f end
        local backOk = step("b")
        if not backOk and f then backOk = nav.back(false) end
        if f then
            finish(f)
            if not backOk then return false, "calibrated but could not return" end
            return true
        end
        return false, "cannot calibrate facing (GPS lost during probe)"
    end
    -- back probe
    if needFuel(2) and step("b") then
        local p1 = nav.gpsLocate()
        local f = p1 and facingFromDelta(p0.x - p1.x, p0.z - p1.z)
        if f then st.facing = f end
        local fwdOk = not turtle.detect() and step("f")
        if f then
            finish(f)
            if not fwdOk then return false, "calibrated but could not return" end
            return true
        end
        return false, "cannot calibrate facing (GPS lost during probe)"
    end
    -- up + forward probe
    if needFuel(4) and not turtle.detectUp() and step("u") then
        if not turtle.detect() and step("f") then
            local p1 = nav.gpsLocate()
            local f = p1 and facingFromDelta(p1.x - p0.x, p1.z - p0.z)
            if f then st.facing = f end
            local okB = step("b")
            local okD = okB and step("d")
            if f then
                finish(f)
                if not (okB and okD) then return false, "calibrated but could not return" end
                return true
            end
            return false, "cannot calibrate facing (GPS lost during probe)"
        end
        step("d")
    end
    local p = nav.gpsLocate()
    if p then st.pos = p end
    return false, "cannot calibrate facing"
end

----------------------------------------------------------------------------
-- recovery
----------------------------------------------------------------------------

local function isNum(v) return type(v) == "number" end

-- Builds the journal timeline. Returns points, pending, replayed(bool)
--   points: {pos, facing, fuel, tag} oldest first; the last point is the "file" state
--   pending: the dangling I entry (only if it belongs to the current snapshot), or nil
local function buildTimeline(entries, snapSeq)
    local points = {}
    local cur, curF = nil, nil
    local lastS, anchor = nil, nil
    for i = 1, #entries do
        local e = entries[i]
        if e.tag == "S" then
            lastS = i
            if e.seq == snapSeq then anchor = i end
        end
    end
    -- the replay segment starts at the S of this snapshot, or at a newer S (snapshot file older
    -- than the journal: trust the journal for position)
    local seg = nil
    if lastS and entries[lastS].seq >= (snapSeq or 0) then seg = lastS end
    if anchor and anchor == lastS then seg = anchor end

    local pending = nil
    for i = 1, #entries do
        local e = entries[i]
        if e.tag == "D" or e.tag == "S" then
            cur = { x = e.x, y = e.y, z = e.z }; curF = e.facing
            points[#points + 1] = { pos = cur, facing = curF, fuel = e.fuel, tag = e.tag, idx = i }
            pending = nil
        elseif e.tag == "R" then
            if cur then
                points[#points + 1] = { pos = cur, facing = curF, fuel = e.fuel, tag = "R", idx = i }
            end
            pending = nil
        elseif e.tag == "I" then
            if seg and i > seg then pending = e else pending = nil end
        end
    end
    if not seg then
        -- stale journal (crash between snapshot and journal rewrite) or none: snapshot is newest
        points[#points + 1] = { pos = copyPos(st.pos), facing = st.facing, fuel = st.saveFuel,
            tag = "snap", idx = #entries + 1 }
        pending = nil
    end
    return points, pending, seg ~= nil
end

local function fail(reason)
    st.lost = reason
    st.phase = "NEEDS_HELP"
    st.reason = reason
    save()
    return false, reason
end

function nav.recover(stIn)
    if stIn then st = stIn end
    local entries = state.readJournal()
    local points, pending = buildTimeline(entries, st.saveSeq)
    local worldFuel = fuel()
    local numeric = isNum(worldFuel)

    local last = points[#points]
    local cur = { pos = copyPos(last.pos), facing = last.facing, fuel = last.fuel }
    local facingDoubt = st.facingUnknown and true or false
    local posUnknown = false
    local reasonFacing = "facing unknown after crash"
    local reasonPos = "position unknown after crash"

    -- step 2: dangling intent
    local unresolved = false
    if pending then
        local isMove = MOVE[pending.op] ~= nil
        if numeric and isNum(pending.fuel) then
            if isMove and worldFuel == pending.fuel - 1 then
                cur.pos, cur.facing = applyOp(cur.pos, cur.facing, pending.op)
                cur.fuel = worldFuel
                points[#points + 1] = { pos = cur.pos, facing = cur.facing, fuel = worldFuel, tag = "D" }
            elseif worldFuel == pending.fuel then
                if not isMove then facingDoubt = true end
            else
                unresolved = true   -- neither: the world rolled back; step 3
            end
        else
            if isMove then posUnknown = true else facingDoubt = true end
        end
    end

    -- step 3: world rollback (fuel in world differs from the journal's latest fuel)
    if numeric and isNum(cur.fuel) and worldFuel ~= cur.fuel then
        local k = nil
        for i = #points, 1, -1 do
            if points[i].fuel == worldFuel then k = i; break end
        end
        if k then
            local lost = 0
            for i = k + 1, #points do
                local a, b = points[i - 1], points[i]
                if not samePos(a.pos, b.pos) then lost = lost + 1 end
            end
            -- all points with this fuel in a row: same position, but turns may separate them
            local j = k
            while j > 1 and points[j - 1].fuel == worldFuel do j = j - 1 end
            for i = j, k do
                if points[i].facing ~= points[k].facing then facingDoubt = true end
            end
            cur.pos = copyPos(points[k].pos); cur.facing = points[k].facing; cur.fuel = worldFuel
            event("warn", "world rollback detected: " .. lost .. " moves lost, back at " .. posStr(cur.pos))
        else
            -- crash in the middle of a refuel: fuel between a point and the R after it
            local found = false
            for i = #points, 2, -1 do
                local p, q = points[i - 1], points[i]
                if q.tag == "R" and isNum(p.fuel) and isNum(q.fuel)
                    and worldFuel > p.fuel and worldFuel < q.fuel then
                    cur.pos = copyPos(p.pos); cur.facing = p.facing; cur.fuel = worldFuel
                    found = true
                    break
                end
            end
            if not found then posUnknown = true; facingDoubt = true end
        end
        unresolved = false
    end
    if unresolved then posUnknown = true end

    -- step 4: GPS
    if st.gps then
        local g = nav.gpsLocate()
        if g then
            if not samePos(g, cur.pos) then
                event("warn", "GPS correction: journal " .. posStr(cur.pos) .. " -> GPS " .. posStr(g))
            end
            cur.pos = g
            posUnknown = false
        end
        st.pos = cur.pos; st.facing = cur.facing
        if posUnknown then return fail(reasonPos .. " (no GPS signal)") end
        if facingDoubt then
            local ok, err = nav.calibrateFacing()
            if not ok then return fail(err or "cannot calibrate facing") end
        end
        st.lost = nil
    else
        st.pos = cur.pos; st.facing = cur.facing
        if posUnknown then return fail(reasonPos) end
        if facingDoubt then return fail(reasonFacing) end
        if st.lost then
            -- an earlier boot could not recover; only RESET_HOME (main) clears this
            save()
            return false, st.lost
        end
    end
    save()
    return true
end

return nav
