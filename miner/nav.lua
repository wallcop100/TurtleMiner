-- Version: 1.1.0
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
--   opts.isKnownOpen(pos) -> bool  cells the caller knows it dug (mine: completed grid cells);
--                                 used with the journal's own positions to settle crashes
--                                 without GPS (see "Known-open map" below)
--   opts.knownBlock(pos) -> name|nil  a stable block known to be there (main: the storage next
--                                 to home), also used by the facing probe
--
-- Fields added to st by this module:
--   st.lost           string|nil  position/facing could not be recovered; recover() and goTo()
--                                 refuse while set. Main clears it on RESET_HOME.
--   st.facingUnknown  bool|nil    set while calibrateFacing() or the no-GPS facing probe is
--                                 running; a crash during either makes the next recover()
--                                 calibrate/probe again.
--   st.facingCands    {int}|nil   no-GPS probe only: the true facing is st.facing + o for one o
--                                 in this list. Journaled turns change st.facing and the true
--                                 facing alike, so the offsets stay valid across probe turns.
--   st.job.noGrid     bool|nil    set after a world rollback: the job's progress may be ahead
--                                 of the world, so grid cells no longer count as known open
--                                 (cleared with the job itself).
--
-- Intent block names: before every turn (and before every move while fuel is "unlimited", where
-- fuel cannot tell whether a move happened) the block seen in the op's inspect direction is
-- stored in the intent line (front for f/b/l/r, up for u, down for d). recover() inspects the
-- same direction again: if the names differ and at least one of them is a stable solid block,
-- the op happened (a stable solid block cannot appear in or vanish from a cell by itself).
-- Equal names, or a difference the world can make by itself (air/fluid/falling blocks/turtles/
-- fluid-generated blocks on both sides), stay ambiguous -> NEEDS_HELP (or GPS calibration).
-- Residual: a player (or another turtle) digging/placing in that one cell during the crash
-- window, or a server rollback of a dig that cost no fuel, can still mislead the comparison.
-- A turn whose side block equals the old front block (stone wall -> stone wall, common at a
-- 1x1 tunnel face) and a move whose next cell equals the destination (air -> air in an open
-- tunnel) cannot be settled without GPS.
--
-- Known-open map (no GPS): a cell is known open when the turtle stood in it (any position in
-- the journal, current segment and history, up to a detected world rollback point) or when
-- opts.isKnownOpen says so. Everything else is unknown: caves, veins and fluids make any
-- unknown cell possibly open. Inspect evidence: air and fluids = open; a stable solid block =
-- solid; falling blocks (gravel/sand can fall into a dug cell), volatile blocks (cobblestone
-- from lava+water, other turtles) and failures = no evidence.
--
-- Turn crash without GPS (inspect cannot settle it): the candidates are "turn did not happen"
-- and "turn happened" (st.facing + 0 or + 1/-1). The probe turns right 3 times (journaled,
-- st.facingUnknown/st.facingCands saved first so a crash mid-probe restarts it with the same
-- candidates plus the one the in-flight probe turn adds), inspects the front cell at each of
-- the 4 facings, and keeps the candidates under which no known-open neighbour shows a stable
-- solid block and no known block (opts.knownBlock) shows a different stable block. Exactly one
-- left = settled. Still ambiguous in the home column below home (shaft: no horizontal cell is
-- known on the first descent): climb the open shaft to home (vertical moves need no facing)
-- and probe there against the home storage. Otherwise NEEDS_HELP. In a 1x1 tunnel the cell the
-- turtle came from alone usually decides it. The same probe settles facings left in doubt by a
-- world rollback (several journal points with the world's fuel, different facings).
--
-- Unlimited fuel, move in flight (air -> air): candidates P (not moved) and Q (moved). Without
-- turning, the front/up/down cells are inspected; a candidate is dropped when it maps a known-
-- open cell (P, Q when the intent saw it empty, the journal, the grid) onto a stable solid
-- block. Exactly one left = settled; otherwise NEEDS_HELP. (Walking back through its own
-- tunnel, every cell around both candidates is open: that case stays NEEDS_HELP.)
-- Residual: a player placing a stable block in a known-open cell during the crash window.
--
-- Moves that dig never dig protected blocks (names containing chest, barrel, shulker,
-- computercraft, turtle): they return false, "protected".

local state = require("state")

local nav = {}

local st = nil
local opts = {}
local movesSinceSave = 0
local gpsFailY = nil        -- st.pos.y of the last failed gps.locate (see nav.gpsLocate)

local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

local MOVE   = { f = "forward", b = "back", u = "up", d = "down" }
local DETECT = { f = "detect", u = "detectUp", d = "detectDown" }
local DIG    = { f = "dig", u = "digUp", d = "digDown" }
local ATTACK = { f = "attack", u = "attackUp", d = "attackDown" }
local INSPECT = { f = "inspect", b = "inspect", l = "inspect", r = "inspect",
                  u = "inspectUp", d = "inspectDown" }

local AIR = "minecraft:air"
local PROTECTED = { "chest", "barrel", "shulker", "computercraft", "turtle" }

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

-- Name of the block in direction fnName ("inspect", "inspectUp", "inspectDown"); AIR when
-- nothing is there; nil when it cannot be told.
local function look(fnName)
    local fn = fnName and turtle[fnName]
    if not fn then return nil end
    local ok, found, data = pcall(fn)
    if not ok then return nil end
    if found then
        if type(data) == "table" and type(data.name) == "string" then return data.name end
        return nil
    end
    return AIR
end

local function isProtected(name)
    if type(name) ~= "string" then return false end
    local n = string.lower(name)
    for i = 1, #PROTECTED do
        if string.find(n, PROTECTED[i], 1, true) then return true end
    end
    return false
end

local function has(n, s) return string.find(n, s, 1, true) ~= nil end

-- "air" | "fluid" | "falling" | "volatile" | "solid" (stable: cannot appear or vanish by itself)
local function blockKind(name)
    local n = string.lower(name)
    if n == AIR or string.find(n, "[:_]air$") then return "air" end
    if has(n, "water") or has(n, "lava") or has(n, "fluid") or has(n, "bubble_column") then
        return "fluid"
    end
    if has(n, "gravel") or (has(n, "sand") and not has(n, "sandstone")) or has(n, "concrete_powder")
        or has(n, "anvil") or has(n, "pointed_dripstone") or has(n, "scaffolding") then
        return "falling"
    end
    if has(n, "cobblestone") or has(n, "obsidian") or has(n, "basalt") or has(n, "ice")
        or has(n, "snow") or has(n, "fire") or has(n, "turtle") or has(n, "computercraft") then
        return "volatile"
    end
    return "solid"
end

-- true only when the change pre -> now proves the op happened (see header)
local function provesOp(pre, now)
    if type(pre) ~= "string" or type(now) ~= "string" or pre == now then return false end
    return blockKind(pre) == "solid" or blockKind(now) == "solid"
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
    local seen = nil
    if op == "l" or op == "r" or before == "unlimited" then seen = look(INSPECT[op]) end
    state.logIntent(op, before, seen)
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

-- nav.init(st, opts): see the header for opts.
function nav.init(stIn, o)
    st = stIn
    opts = o or {}
    movesSinceSave = 0
    gpsFailY = nil
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
            if isProtected(look(INSPECT[op])) then return false, "protected" end
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
            -- entity in the way (mob, falling gravel, player). A hit is not progress: a mob
            -- that never dies or leaves must still end in "timeout" after STUCK_TIMEOUT.
            turtle[ATTACK[op]]()
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
    local toHome = type(st.home) == "table" and samePos(tgt, st.home)
    local ok, err = runOrder(order, tgt, dig)
    if not ok and err ~= "abort" and err ~= "no_fuel" then
        local alt = string.reverse(order)
        -- never climb first towards home: that digs straight up through the base
        local climbFirst = string.sub(alt, 1, 1) == "y" and tgt.y > st.pos.y
        if not (toHome and climbFirst) then
            ok, err = runOrder(alt, tgt, dig)
        end
    end
    if not ok then return false, err end
    if not samePos(st.pos, tgt) then return false, "not at target" end
    if opts2.facing ~= nil then return nav.face(opts2.facing) end
    return true
end

----------------------------------------------------------------------------
-- GPS
----------------------------------------------------------------------------

-- Wireless modems reach 64 blocks, so underground gps.locate usually times out (2 s). After a
-- failed locate, nav.gpsLocate() returns nil at once until the turtle has climbed GPS_RETRY_UP
-- blocks above the failure, or is within GPS_NEAR_HOME blocks of home (or force is true).
local GPS_RETRY_UP, GPS_NEAR_HOME = 16, 16

function nav.gpsLocate(force)
    if not st or not st.gps or not gps or not gps.locate then return nil end
    if gpsFailY and not force and type(st.pos) == "table" then
        local near = type(st.home) == "table" and nav.dist(st.pos, st.home) <= GPS_NEAR_HOME
        if not near and st.pos.y < gpsFailY + GPS_RETRY_UP then return nil end
    end
    local ok, x, y, z = pcall(gps.locate, 2)
    if not ok or not x or not y or not z then
        gpsFailY = type(st.pos) == "table" and st.pos.y or nil
        return nil
    end
    gpsFailY = nil
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

-- Moves one block, compares GPS fixes, returns to the start. Probe order: forward, back,
-- up+forward, turn right up to 3 times probing forward after each turn (1x1 tunnel), and,
-- only when not at home, dig one non-protected block in one of the four directions and probe
-- into it. Turns are journaled and st.facingUnknown stays set until the result is saved, so a
-- crash during the probe makes the next recover() calibrate again. Never guesses.
function nav.calibrateFacing()
    if not st.gps then return false, "cannot calibrate facing (no GPS mode)" end
    local p0 = nav.gpsLocate()
    if not p0 then return false, "cannot calibrate facing (no GPS signal)" end
    st.pos = p0
    st.facingUnknown = true
    save()
    local atHome = type(st.home) == "table" and samePos(p0, st.home)

    local function finish(f)
        st.facing = f
        st.facingUnknown = nil
        st.facingCands = nil
        local p = nav.gpsLocate()
        if p then st.pos = p end
        save()
        return true
    end

    local function needFuel(n)
        local f = fuel()
        return f == "unlimited" or f >= n
    end

    -- forward probe from where the turtle stands and faces now.
    -- nil: no room (try something else); true | false, reason: final answer
    local function probeForward()
        if not needFuel(2) or turtle.detect() or not step("f") then return nil end
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

    local r, why = probeForward()
    if r ~= nil then return r, why end
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
    -- turn and probe the other horizontal directions (turns cost no fuel). The probe measures
    -- the facing after these turns, so the turns need no further accounting.
    for _ = 1, 3 do
        if not step("r") then break end
        r, why = probeForward()
        if r ~= nil then return r, why end
    end
    -- boxed in: away from home, dig one block to make room (never a protected block)
    if not atHome and needFuel(2) then
        for k = 1, 4 do
            if turtle.detect() and not isProtected(look("inspect")) then
                for _ = 1, 5 do
                    if not turtle.detect() then break end
                    if not turtle.dig() then break end
                    if turtle.detect() then sleep(0.4) end   -- falling gravel/sand
                end
                r, why = probeForward()
                if r ~= nil then return r, why end
            end
            if k < 4 and not step("r") then break end
        end
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

local function posKey(p) return p.x .. "," .. p.y .. "," .. p.z end

-- what an inspect result says about a cell (see "Known-open map" in the header)
local function evidence(name)
    if type(name) ~= "string" then return nil end
    local k = blockKind(name)
    if k == "air" or k == "fluid" then return "open" end
    if k == "solid" then return "solid" end
    return nil
end

-- isOpen(pos) for the known-open map: journal points 1..upto, plus the caller's grid cells
local function knownOpenMap(points, upto, useGrid)
    local set = {}
    for i = 1, upto do
        local p = points[i] and points[i].pos
        if p then set[posKey(p)] = true end
    end
    return function(p)
        if set[posKey(p)] then return true end
        if useGrid and opts.isKnownOpen then
            local ok, r = pcall(opts.isKnownOpen, { x = p.x, y = p.y, z = p.z })
            return ok and r == true
        end
        return false
    end
end

local function offsetList(set)
    local l = {}
    for o = 0, 3 do if set[o] then l[#l + 1] = o end end
    return l
end

local function knownBlock(p)
    if not opts.knownBlock then return nil end
    local ok, r = pcall(opts.knownBlock, { x = p.x, y = p.y, z = p.z })
    if ok and type(r) == "string" and blockKind(r) == "solid" then return r end
    return nil
end

-- No-GPS facing probe (see header). st.pos is known; true facing = st.facing + o, o in offs.
-- Returns true, or false + number of consistent candidates.
local function probeFacingHere(offs, isOpen)
    st.facingUnknown = true
    st.facingCands = offsetList(offs)
    save()
    local f0 = st.facing
    local names = {}
    for i = 0, 3 do
        if i > 0 and not step("r") then return false, -1 end
        names[i] = look("inspect")
    end
    local match = {}
    for _, o in ipairs(st.facingCands) do
        local ok = true
        for i = 0, 3 do
            local d = (f0 + o + i) % 4
            local n = { x = st.pos.x + DX[d], y = st.pos.y, z = st.pos.z + DZ[d] }
            local ev = evidence(names[i])
            if ev == "solid" and isOpen(n) then ok = false; break end
            local kb = knownBlock(n)
            if kb and ev == "solid" and names[i] ~= kb then ok = false; break end
        end
        if ok then match[#match + 1] = o end
    end
    if #match ~= 1 then return false, #match end
    st.facing = (st.facing + match[1]) % 4
    st.facingUnknown = nil
    st.facingCands = nil
    save()
    return true
end

-- Probe here; still ambiguous below home in its column (shaft): climb the open shaft to home
-- and probe there. Offsets survive vertical moves (they never change the facing).
local function probeFacing(offs, isOpen)
    local ok, n = probeFacingHere(offs, isOpen)
    if ok or n == -1 then return ok, n end
    local h = st.home
    if type(h) ~= "table" or st.pos.x ~= h.x or st.pos.z ~= h.z or st.pos.y >= h.y then return ok, n end
    local cands = {}
    for _, o in ipairs(st.facingCands or {}) do cands[o] = true end
    while st.pos.y < h.y do
        local fl = fuel()
        if fl ~= "unlimited" and fl < 1 then return false, n end
        if turtle.detectUp() or not step("u") then return false, n end
    end
    event("info", "facing unknown in the shaft: climbed home to probe there")
    return probeFacingHere(cands, isOpen)
end

-- Unlimited fuel, move op in flight (see header). Returns the settled position or nil.
-- useFront: the facing is known (front inspect means something).
local function settleMove(P, facing, pend, isOpen, useFront)
    local Q = applyOp(P, facing, pend.op)
    local qOpen = pend.op ~= "b" and evidence(pend.front) == "open"
    local function known(c)
        return samePos(c, P) or (qOpen and samePos(c, Q)) or isOpen(c)
    end
    local obs = { u = evidence(look("inspectUp")), d = evidence(look("inspectDown")) }
    if useFront then obs.f = evidence(look("inspect")) end
    local function consistent(X)
        for dir, ev in pairs(obs) do
            if ev == "solid" and known((applyOp(X, facing, dir))) then return false end
        end
        return true
    end
    local a, b = consistent(P), consistent(Q)
    if a and not b then return P end
    if b and not a then return Q end
    return nil
end

function nav.recover(stIn)
    if stIn then st = stIn end
    local entries = state.readJournal()
    local points, pending = buildTimeline(entries, st.saveSeq)
    local worldFuel = fuel()
    local numeric = isNum(worldFuel)

    local last = points[#points]
    local cur = { pos = copyPos(last.pos), facing = last.facing, fuel = last.fuel }
    -- facing offsets: the true facing is cur.facing + o for some o in offs
    local offs = { [0] = true }
    if st.facingUnknown then
        if not st.gps and type(st.facingCands) == "table" and #st.facingCands > 0 then
            offs = {}
            for _, o in ipairs(st.facingCands) do
                if type(o) == "number" then offs[math.floor(o) % 4] = true end
            end
        else
            offs = { [0] = true, [1] = true, [2] = true, [3] = true }
        end
    end
    local turnByInspect = false
    local posUnknown = false
    local knownUpto = #points     -- journal points whose cells the world still has open
    local rolledBack = false
    local movePending = nil       -- unlimited fuel: move that may or may not have happened
    local reasonFacing = "facing unknown after crash"
    local reasonPos = "position unknown after crash"

    -- step 2: dangling intent
    local unresolved = false
    -- inspect in the op's direction and compare with the block stored in the intent
    local function inspectProves(op)
        if not pending.front or not INSPECT[op] then return false end
        return provesOp(pending.front, look(INSPECT[op]))
    end
    local function settleTurn()
        if inspectProves(pending.op) then
            -- the turn happened; it changes the journal facing and the true facing alike
            cur.pos, cur.facing = applyOp(cur.pos, cur.facing, pending.op)
            turnByInspect = true
            event("info", "turn in flight at crash settled by inspect (block in front changed)")
        else
            local d = (pending.op == "r") and 1 or 3
            local n = {}
            for o in pairs(offs) do n[o] = true; n[(o + d) % 4] = true end
            offs = n
        end
    end
    if pending then
        local isMove = MOVE[pending.op] ~= nil
        if numeric and isNum(pending.fuel) then
            if isMove and worldFuel == pending.fuel - 1 then
                cur.pos, cur.facing = applyOp(cur.pos, cur.facing, pending.op)
                cur.fuel = worldFuel
                points[#points + 1] = { pos = cur.pos, facing = cur.facing, fuel = worldFuel, tag = "D" }
                knownUpto = #points
            elseif worldFuel == pending.fuel then
                if not isMove then settleTurn() end
            else
                unresolved = true   -- neither: the world rolled back; step 3
            end
        elseif isMove then
            -- unlimited fuel: only the block in the move direction can tell
            if not numeric and inspectProves(pending.op) then
                cur.pos, cur.facing = applyOp(cur.pos, cur.facing, pending.op)
                event("info", "move in flight at crash settled by inspect")
            else
                posUnknown = true
                if not numeric then movePending = pending end
            end
        else
            settleTurn()
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
            -- all points with this fuel in a row: same position, but turns may separate them;
            -- the world stopped at one of them, so its facing is one of theirs
            local j = k
            while j > 1 and points[j - 1].fuel == worldFuel do j = j - 1 end
            local n = {}
            for i = j, k do n[(points[i].facing - points[k].facing) % 4] = true end
            if st.facingUnknown then n = { [0] = true, [1] = true, [2] = true, [3] = true } end
            offs = n
            cur.pos = copyPos(points[k].pos); cur.facing = points[k].facing; cur.fuel = worldFuel
            knownUpto, rolledBack = k, true
            event("warn", "world rollback detected: " .. lost .. " moves lost, back at " .. posStr(cur.pos))
        else
            -- crash in the middle of a refuel: fuel between a point and the R after it
            local found = false
            for i = #points, 2, -1 do
                local p, q = points[i - 1], points[i]
                if q.tag == "R" and isNum(p.fuel) and isNum(q.fuel)
                    and worldFuel > p.fuel and worldFuel < q.fuel then
                    cur.pos = copyPos(p.pos); cur.facing = p.facing; cur.fuel = worldFuel
                    knownUpto, rolledBack = i - 1, true
                    found = true
                    break
                end
            end
            if not found and worldFuel > cur.fuel and not pending then
                -- fuel rose with no R line: crash between turtle.refuel and logRefuel. A refuel
                -- never moves or turns the turtle, so the replayed position stands.
                cur.fuel = worldFuel
                found = true
                event("info", "fuel rose without a journal record (refuel before crash), position kept")
            end
            if not found then
                posUnknown = true
                offs = { [0] = true, [1] = true, [2] = true, [3] = true }
            end
        end
        unresolved = false
    end
    if unresolved then posUnknown = true end
    local nOffs = #offsetList(offs)
    local facingDoubt = not (nOffs == 1 and offs[0])

    if rolledBack and type(st.job) == "table" then st.job.noGrid = true end
    -- after a rollback the journal lines past the rollback point name cells the world lost
    local function finalSave()
        if rolledBack then return state.save(st, true) end
        return save()
    end

    -- step 4: GPS. Underground a GPS turtle is usually out of modem range (64 blocks): with no
    -- fix it recovers exactly like a blind turtle (journal, inspect, known-open map probing).
    local g = st.gps and nav.gpsLocate() or nil
    local isOpen = knownOpenMap(points, knownUpto, not rolledBack)
    if g then
        local corrected = not samePos(g, cur.pos)
        if corrected then
            event("warn", "GPS correction: journal " .. posStr(cur.pos) .. " -> GPS " .. posStr(g))
            -- the inspect comparison assumed the journal position
            if turnByInspect then facingDoubt = true end
        end
        cur.pos = g
        posUnknown = false
        st.pos = cur.pos; st.facing = cur.facing
        if facingDoubt then
            if rolledBack then finalSave() end
            local ok, err = nav.calibrateFacing()
            if not ok and not corrected and st.facingUnknown and not st.facingCands then
                -- GPS answered once but not for the calibration (edge of range): the journal
                -- position was right, so the blind probe applies. calibrateFacing's own turns
                -- are journaled, so every facing is a candidate relative to st.facing now.
                local pok, n = probeFacing({ [0] = true, [1] = true, [2] = true, [3] = true }, isOpen)
                if pok then
                    ok = true
                    event("info", "facing settled by probing (GPS calibration failed: " .. tostring(err) .. ")")
                end
            end
            if not ok then return fail(err or "cannot calibrate facing") end
        end
        st.lost = nil
    else
        local sfx = st.gps and " (no GPS signal)" or ""
        st.pos = cur.pos; st.facing = cur.facing
        if st.lost then
            -- an earlier boot could not recover; only RESET_HOME (main) clears this
            finalSave()
            return false, st.lost
        end
        if posUnknown and movePending then
            local q = settleMove(cur.pos, cur.facing, movePending, isOpen, not facingDoubt)
            if q then
                event("info", "move in flight at crash settled by the known-open map at " .. posStr(q))
                cur.pos = q
                st.pos = copyPos(q)
                posUnknown = false
            end
        end
        if posUnknown then return fail(reasonPos .. sfx) end
        if facingDoubt and nOffs == 1 then
            st.facing = (st.facing + offsetList(offs)[1]) % 4
        elseif facingDoubt then
            if rolledBack then finalSave() end   -- the probe's own saves keep only clean lines
            local ok, n = probeFacing(offs, isOpen)
            if not ok then
                return fail(reasonFacing .. ((n and n > 1) and (" (probe: " .. n .. " facings fit)")
                    or " (probe: no facing fits)") .. sfx)
            end
            event("info", "facing after crash settled by probing the 4 neighbours")
        end
    end
    finalSave()
    return true
end

return nav
