-- Version: 1.2.0
-- TurtleMiner mining pattern (WP-B).
-- Grid in the home frame (F = homeFacing, R = homeFacing + 1), all at cfg.TARGET_Y:
--   shaft  : home x/z, home y -> TARGET_Y
--   spine  : f = 1, along R, r = 0 .. c*W         (W = 2*BRANCH_LENGTH + BRANCH_SPACING)
--   main c : r = c*W, along F, f = 1 .. MAIN_LENGTH
--   branch : f = 1 + (b+1)*BRANCH_SPACING, sides L (-R) and R (+R), BRANCH_LENGTH long
-- st.job = {corridor, branch, side, step} is advanced as work completes. Every leg is walked
-- with the same step function, which digs only what is still solid, so resuming from any job
-- (or any position) just re-walks open tunnel and continues. Never goes home by itself.

local mine = {}

local st, cfg, nav, inv, ctl

local UP, DOWN = 4, 5
local DVEC = { [0] = { 0, -1 }, [1] = { 1, 0 }, [2] = { 0, 1 }, [3] = { -1, 0 } } -- dx, dz

local stepCount = 0
local dug = {}         -- positions opened by vein mining this run (count as fresh tunnel)
local seen = {}        -- cells inspected this run (no need to turn and look again)
local oreSet, oreSrc = nil, nil
local ready = false    -- mine.init called
local veinFrom, veinPath = nil, nil   -- while in a vein: its start position and the path stack
-- Army mode (miner/group.lua): grid in the station frame (home = station spot), see the army section at the end.
local armyOn = false      -- member of an army: wait for unknown turtles, all ores wanted, no solo grid
local aj = nil            -- current army branch {key,y,c,b,side,bl,sp,ml,near={}}
local armyInfo = nil      -- {geom=, deepest=} from the army record (fuel estimates before a claim)
local armyOres = {}       -- ore family -> count since the last claim_done
local armyStart, armyRetreat, armyRouteLen   -- defined in the army section

-- ------------------------------------------------------------------ helpers

local function key(p) return p.x .. "," .. p.y .. "," .. p.z end

local function neighbor(p, d)
    if d == UP then return { x = p.x, y = p.y + 1, z = p.z } end
    if d == DOWN then return { x = p.x, y = p.y - 1, z = p.z } end
    local v = DVEC[d]
    return { x = p.x + v[1], y = p.y, z = p.z + v[2] }
end

local function stats()
    if type(st.stats) ~= "table" then st.stats = { ores = 0, blocks = 0, trips = 0 } end
    st.stats.ores = st.stats.ores or 0
    st.stats.blocks = st.stats.blocks or 0
    return st.stats
end

local function ctlCheck()
    if ctl and ctl.check then return ctl.check() end
    return nil
end

local function event(level, text)
    if ctl and ctl.event then pcall(ctl.event, level, text) end
end

local function saveState()
    local ok, state = pcall(require, "state")
    if ok and type(state) == "table" and state.save then pcall(state.save, st) end
end

local function FD() return st.homeFacing % 4 end
local function RD() return (st.homeFacing + 1) % 4 end

-- World pos -> frame (f, r). The frame basis is orthonormal so the inverse is the transpose.
local function frame(p)
    local dx, dz = p.x - st.home.x, p.z - st.home.z
    local F, R = DVEC[FD()], DVEC[RD()]
    return dx * F[1] + dz * F[2], dx * R[1] + dz * R[2]
end

function mine.toWorld(f, r, y)
    local F, R = DVEC[FD()], DVEC[RD()]
    return {
        x = math.floor(st.home.x + f * F[1] + r * R[1]),
        y = math.floor(y),
        z = math.floor(st.home.z + f * F[2] + r * R[2]),
    }
end

local function targetY() return math.floor(cfg.TARGET_Y) end

-- Grid geometry is frozen into the job when it starts, so changing BRANCH_LENGTH etc. mid-job
-- can never make a new corridor overlap an old one. It is re-read from cfg on a job reset.
local function geom()
    local g = st.job.geom
    if type(g) ~= "table" or not g.bl then
        -- y: the level this job's grid was started at (mine.isKnownOpen trusts the grid only
        -- while TARGET_Y still equals it)
        g = { bl = cfg.BRANCH_LENGTH, sp = cfg.BRANCH_SPACING, ml = cfg.MAIN_LENGTH, y = targetY() }
        st.job.geom = g
    end
    return g
end
local function width() local g = geom(); return 2 * g.bl + g.sp end
local function numBranches() local g = geom(); return math.floor((g.ml - 1) / g.sp) end
local function branchF(b) return 1 + (b + 1) * geom().sp end
local function nearestMain(r) local w = width(); return math.floor(r / w + 0.5) * w end

local function newJob()
    return { corridor = 0, branch = 0, side = "L", step = 0 }
end

local function ensureJob()
    if type(st.job) ~= "table" or type(st.job.corridor) ~= "number" then st.job = newJob() end
    local j = st.job
    j.branch = j.branch or 0
    j.side = (j.side == "R") and "R" or "L"
    j.step = j.step or 0
    geom()
    return j
end

local function isProtected(data)
    local n = type(data) == "table" and data.name
    if type(n) ~= "string" then return false end
    return n:find("chest") ~= nil or n:find("barrel") ~= nil or n:find("shulker") ~= nil
        or n:find("crate") ~= nil or n:find("^computercraft:") ~= nil
end
mine.isProtected = isProtected

-- Is world cell p part of the planned grid (shaft bottom, spine, mains, branches of every
-- corridor below MAX_CORRIDORS)? Such a cell is open already or will be dug (and its ore
-- taken) by the step that enters it, so a scan never needs to turn to look at it.
local function isTunnel(p)
    if armyOn then return false end
    if p.y ~= targetY() then return false end
    local f, r = frame(p)
    local g = geom()
    local w = width()
    local maxC = math.max(1, cfg.MAX_CORRIDORS or 1)
    local lastR = (maxC - 1) * w
    if f == 0 and r == 0 then return true end
    if f == 1 and r >= 0 and r <= lastR then return true end
    local c = math.floor(r / w + 0.5)
    if c < 0 or c >= maxC then return false end
    local off = math.abs(r - c * w)
    if off == 0 then return f >= 1 and f <= g.ml end
    if off > g.bl or f < 1 + g.sp then return false end
    return (f - 1) % g.sp == 0 and (f - 1) / g.sp - 1 < numBranches()
end

-- ------------------------------------------------------------------ ores

local function buildOreSet()
    if oreSrc == cfg.ORES and oreSet then return oreSet end
    oreSet, oreSrc = {}, cfg.ORES
    if type(cfg.ORES) == "table" then
        for _, o in ipairs(cfg.ORES) do
            local b = (o:match(":(.+)$") or o):gsub("^deepslate_", "")
            oreSet[b] = true
        end
    end
    return oreSet
end

-- Ore family: "deepslate_iron_ore", "iron_ore" and "raw_iron_block" (1.18 large veins) are all
-- "iron", so they form one vein and FOCUS=iron matches every variant.
local function familyOf(base)
    local raw = base:match("^raw_(.+)_block$")
    if raw then return raw end
    return (base:gsub("_ore$", ""))
end
mine.familyOf = familyOf

function mine.isOre(data)
    if type(data) ~= "table" or type(data.name) ~= "string" then return false end
    local base = (data.name:match(":(.+)$") or data.name):gsub("^deepslate_", "")
    if buildOreSet()[base] then return true, familyOf(base) end
    local tags = data.tags
    if type(tags) == "table" and (tags["c:ores"] or tags["forge:ores"]) then return true, familyOf(base) end
    return false
end

local function wanted(family)
    if armyOn then return true end   -- the level's focus only orders the work; any ore on the way is taken
    local f = cfg.FOCUS
    if f == nil or f == "" or f == "all" then return true end
    f = familyOf(f)   -- accept "iron_ore" / "raw_iron_block" as well as "iron"
    return family == f or family:find(f, 1, true) ~= nil
end

-- ------------------------------------------------------------------ primitive moves

local function look(d)
    seen[key(neighbor(st.pos, d))] = true
    if d == UP then return turtle.inspectUp() end
    if d == DOWN then return turtle.inspectDown() end
    if st.facing ~= d then nav.face(d) end
    return turtle.inspect()
end

local function moveDir(d, dig)
    if d == UP then return nav.up(dig) end
    if d == DOWN then return nav.down(dig) end
    if st.facing ~= d then nav.face(d) end
    return nav.forward(dig)
end

local function isTurtleBlock(data)
    return type(data) == "table" and type(data.name) == "string" and data.name:find("^computercraft:turtle") ~= nil
end

-- Army: a turtle in front that did not get the cell from the coordinator. Never dig or attack it:
-- wait until it is gone or STUCK_TIMEOUT passes. Returns true (cell free) or false, signal|text.
local function waitTurtle(d)
    local t0, limit = os.clock(), cfg.STUCK_TIMEOUT or 60
    local p = neighbor(st.pos, d)
    while true do
        local c = ctlCheck()
        if c then return false, c, true end
        sleep(1)
        local present, data = look(d)
        if not (present and isTurtleBlock(data)) then return true end
        if os.clock() - t0 >= limit then
            return false, "blocked by unknown turtle at " .. p.x .. "," .. p.y .. "," .. p.z
        end
    end
end

-- Move in direction d, digging what is in the way, but never a protected block (chest,
-- computer, ...): that fails with reason "protected" and a detail naming the block.
local function safeMove(d)
    local present, data = look(d)
    if armyOn and present and isTurtleBlock(data) then
        local ok, why = waitTurtle(d)
        if not ok then return false, "protected", why end
        present, data = look(d)
    end
    if present and isProtected(data) then
        local p = st.pos
        return false, "protected", "protected block " .. tostring(data.name) .. " next to "
            .. p.x .. "," .. p.y .. "," .. p.z
    end
    return moveDir(d, true)
end

-- Undo a step made in direction d. Backs up without turning when the cell is open.
local function backStep(d)
    if d == UP then return safeMove(DOWN) end
    if d == DOWN then return safeMove(UP) end
    if st.facing == d then
        local ok, reason = nav.back(false)
        if ok or reason ~= "blocked" then return ok, reason end
    end
    return safeMove((d + 2) % 4)
end

local function digDir(d)
    if d == UP then return turtle.digUp() end
    if d == DOWN then return turtle.digDown() end
    if st.facing ~= d then nav.face(d) end
    return turtle.dig()
end

-- Map a nav failure to a mine.run result.
local function fail(reason)
    if reason == "abort" then return ctlCheck() or "return", "abort" end
    if reason == "no_fuel" then return "fuel", "out of fuel" end
    local p = st.pos
    return "stuck", tostring(reason) .. " at " .. p.x .. "," .. p.y .. "," .. p.z
end

-- Low on fuel: burn what we carry before giving up and heading home
-- (BURN_COAL only decides whether to top up all the way to FUEL_TARGET).
local function fuelGood()
    if inv.fuelOk(st) then return true end
    local want = inv.fuelNeeded(st) + 1
    if cfg.BURN_COAL then want = math.max(cfg.FUEL_TARGET or 0, want) end
    inv.refuel(want)
    return inv.fuelOk(st)
end

local function roomGood()
    if not inv.isFull() then return true end
    if cfg.DROP_TRASH then inv.dropTrash() end
    return not inv.isFull()
end

-- ------------------------------------------------------------------ vein mining

-- Iterative DFS from the current position over blocks of `family`. Moves into each ore block,
-- backtracks along its own path, and always ends at the start position and facing.
-- Returns count, signal|nil, reason. Signals: "return"/"stop" (command), "stuck".
-- Running out of room or fuel just ends the vein; the caller's next step reports it.
function mine.vein(family, noRestore)
    local prevPhase = st.phase
    st.phase = "VEIN"
    local startFacing = st.facing
    local checked = { [key(st.pos)] = true }
    if armyOn and aj then for k in pairs(aj.near) do checked[k] = true end end   -- already dug by others
    local path = {}
    veinFrom, veinPath = { x = st.pos.x, y = st.pos.y, z = st.pos.z }, path
    local function done(...)
        veinFrom, veinPath = nil, nil
        st.phase = prevPhase
        return ...
    end
    local count, sig, why = 0, nil, nil
    local max = cfg.VEIN_MAX or 64
    local s = stats()

    local function findNext()
        -- front, then round one way: at most 3 turns per cell
        local dirs = { UP, DOWN, st.facing, (st.facing + 1) % 4, (st.facing + 2) % 4, (st.facing + 3) % 4 }
        for _, d in ipairs(dirs) do
            local k = key(neighbor(st.pos, d))
            if not checked[k] then
                checked[k] = true
                local present, data = look(d)
                if present then
                    local ore, fam = mine.isOre(data)
                    if ore and fam == family then return d end
                end
            end
        end
        return nil
    end

    while true do
        local nextDir = nil
        if count < max then
            local c = ctlCheck()
            if c then sig, why = c, "command"; break end
            if fuelGood() and roomGood() then nextDir = findNext() end
        end
        if nextDir then
            local ok, reason = moveDir(nextDir, true)
            if ok then
                path[#path + 1] = nextDir
                dug[key(st.pos)] = true
                count = count + 1
                if armyOn then
                    armyOres[family] = (armyOres[family] or 0) + 1
                    if ctl and ctl.dig then pcall(ctl.dig, st.pos) end
                end
                s.ores = s.ores + 1
                s.blocks = s.blocks + 1
            elseif reason == "abort" then
                sig, why = ctlCheck() or "return", "abort"
                break
            elseif reason == "no_fuel" then
                break
            end -- unbreakable/timeout: that block stays marked checked and is skipped
        else
            if #path == 0 then break end
            local ok, reason, detail = backStep(path[#path])
            if not ok then
                return done(count, "stuck", "vein backtrack failed: " .. tostring(detail or reason))
            end
            table.remove(path)
        end
    end
    while #path > 0 do
        local ok, reason, detail = backStep(path[#path])
        if not ok then
            return done(count, "stuck", "vein backtrack failed: " .. tostring(detail or reason))
        end
        table.remove(path)
    end
    -- callers inside mine.lua turn to whatever they look at next anyway (saves turns)
    if not noRestore and st.facing ~= startFacing then nav.face(startFacing) end
    if count > 1 then event("info", "vein " .. family .. " x" .. count) end
    return done(count, sig, why)
end

local function takeOre(d, family)
    if cfg.VEIN_MINING then
        local _, sig, why = mine.vein(family, true)
        return sig, why
    end
    if digDir(d) then
        if armyOn then armyOres[family] = (armyOres[family] or 0) + 1 end
        local s = stats()
        s.ores = s.ores + 1
        s.blocks = s.blocks + 1
    end
    return nil
end

-- ------------------------------------------------------------------ walking

-- Look at the five open faces after moving in direction d and take any wanted ore.
-- Side faces cost turns (and a turn is what a crash leaves ambiguous), so a side face is only
-- looked at when it was not inspected yet this run and is not a planned tunnel cell. Up, down
-- and front need no turn and are always inspected.
local function scan(d)
    local cand, free
    if d == UP or d == DOWN then
        local f = st.facing
        cand, free = { d, f, (f + 1) % 4, (f + 2) % 4, (f + 3) % 4 }, 2
    else
        cand, free = { UP, DOWN, d, (d + 3) % 4, (d + 1) % 4 }, 3
    end
    local dirs = {}
    for i, dir in ipairs(cand) do
        local n = neighbor(st.pos, dir)
        if i <= free or (not seen[key(n)] and not isTunnel(n)) then dirs[#dirs + 1] = dir end
    end
    for _, dir in ipairs(dirs) do
        local present, data = look(dir)
        if present then
            local ore, fam = mine.isOre(data)
            if ore and wanted(fam) then
                local sig, why = takeOre(dir, fam)
                if sig then return sig, why end
            end
        end
    end
    return nil
end

local function preStep()
    stepCount = stepCount + 1
    local c = ctlCheck()
    if c then return c, "command" end
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" then
        if cfg.BURN_COAL and fuel < (cfg.FUEL_TARGET or 0) and stepCount % 16 == 0 then
            inv.refuel(cfg.FUEL_TARGET)
        end
        if not fuelGood() then
            return "fuel", "fuel " .. tostring(turtle.getFuelLevel()) .. " below needed " .. inv.fuelNeeded(st)
        end
    end
    if not roomGood() then return "full", "inventory full" end
    return nil
end

-- One block in direction d: checks, ore in the way, move, scan if the block was new.
local function step(d)
    local sig, why = preStep()
    if sig then return sig, why end
    local present, data = look(d)
    local counted = false
    if armyOn and present and isTurtleBlock(data) then
        local ok, why, isSig = waitTurtle(d)
        if not ok then
            if isSig then return why, "command" end
            return "stuck", why
        end
        present, data = look(d)
    end
    if present then
        if isProtected(data) then
            local p = st.pos
            return "stuck", "protected block " .. tostring(data.name) .. " next to " .. p.x .. "," .. p.y .. "," .. p.z
        end
        local ore, fam = mine.isOre(data)
        if ore and wanted(fam) then
            sig, why = takeOre(d, fam)
            if sig then return sig, why end
            counted = true
        end
    end
    local fresh = present or dug[key(neighbor(st.pos, d))]
    local ok, reason = moveDir(d, true)
    if not ok then return fail(reason) end
    if present and not counted then
        local s = stats()
        s.blocks = s.blocks + 1
    end
    if fresh then return scan(d) end
    return nil
end

-- Walk along one frame axis ("f", "r" or "y") to `target`, calling onStep after each move.
local function axisPos(axis)
    if axis == "y" then return st.pos.y end
    local f, r = frame(st.pos)
    if axis == "f" then return f end
    return r
end

local function axisDir(axis, up)
    if axis == "y" then return up and UP or DOWN end
    local d = (axis == "f") and FD() or RD()
    return up and d or (d + 2) % 4
end

local function lineTo(axis, target, onStep)
    local limit = math.abs(target - axisPos(axis)) + 1
    local n = 0
    while true do
        local c = axisPos(axis)
        if c == target then return nil end
        n = n + 1
        if n > limit then return "stuck", "position not advancing on axis " .. axis end
        local sig, why = step(axisDir(axis, target > c))
        if sig then return sig, why end
        if onStep then onStep() end
    end
end

-- From anywhere, reach main-tunnel position (ft, rt) at TARGET_Y through the grid's own tunnels:
-- shaft -> spine (f=1) -> main. Leaves a branch back to its main first.
local function route(ft, rt)
    local T = targetY()
    local sig, why
    if st.pos.y ~= T then
        sig, why = lineTo("y", T)
        if sig then return sig, why end
    end
    local f, r = frame(st.pos)
    if f == 0 and r == 0 then
        sig, why = lineTo("f", 1)
        if sig then return sig, why end
        f, r = frame(st.pos)
    end
    if r ~= rt then
        local m = nearestMain(r)
        if f ~= 1 and m ~= r then
            sig, why = lineTo("r", m)
            if sig then return sig, why end
            r = m
        end
        if r ~= rt then
            if f ~= 1 then
                sig, why = lineTo("f", 1)
                if sig then return sig, why end
            end
            sig, why = lineTo("r", rt)
            if sig then return sig, why end
        end
    end
    return lineTo("f", ft)
end

local function sideDir(side)
    if side == "L" then return (RD() + 2) % 4, -1 end
    return RD(), 1
end

function mine.jobStart(job)
    if armyOn and armyStart then return armyStart() end
    job = job or st.job
    local T = targetY()
    local rc = job.corridor * width()
    if job.branch >= numBranches() then
        return mine.toWorld(geom().ml, rc, T), FD()
    end
    local d = sideDir(job.side)
    return mine.toWorld(branchF(job.branch), rc, T), d
end

local function doBranch(job)
    local g = geom()
    local fb = branchF(job.branch)
    local rc = job.corridor * width()
    local _, sign = sideDir(job.side)
    local f, r = frame(st.pos)
    local inRow = st.pos.y == targetY() and f == fb and (r - rc) * sign >= 0 and math.abs(r - rc) <= g.bl
    if not inRow then
        local sig, why = route(fb, rc)
        if sig then return sig, why end
    end
    return lineTo("r", rc + sign * g.bl, function()
        local _, r2 = frame(st.pos)
        job.step = math.abs(r2 - rc)
    end)
end

local function advance(job)
    if job.side == "L" then
        job.side = "R"
    else
        job.side = "L"
        job.branch = job.branch + 1
    end
    job.step = 0
    saveState()
end

-- ------------------------------------------------------------------ public

function mine.init(st_, cfg_, nav_, inv_, ctl_)
    st, cfg, nav, inv, ctl = st_, cfg_, nav_, inv_, ctl_
    ready = true
    seen = {}
    veinFrom, veinPath = nil, nil
    dug = {}
    stepCount = 0
    oreSet, oreSrc = nil, nil
end

local function atHome()
    local p, h = st.pos, st.home
    return p.x == h.x and p.y == h.y and p.z == h.z
end

function mine.run()
    dug = {}
    seen = {}
    if type(st.flags) == "table" and st.flags.resetJob and atHome() then
        st.job = newJob()
        st.flags.resetJob = false
    end
    local job = ensureJob()
    while true do
        if job.corridor >= (cfg.MAX_CORRIDORS or 1) then
            return "done", "all " .. job.corridor .. " corridors mined"
        end
        local rc = job.corridor * width()
        if job.branch >= numBranches() then
            -- corridor finished: finish its main tunnel, then start the next corridor
            local sig, why = route(geom().ml, rc)
            if sig then return sig, why end
            job.corridor = job.corridor + 1
            job.branch, job.side, job.step = 0, "L", 0
            event("info", "corridor " .. (job.corridor - 1) .. " done")
            saveState()
        elseif job.step >= geom().bl then
            advance(job)
        else
            local sig, why = doBranch(job)
            if sig then return sig, why end
            job.step = geom().bl
            advance(job)
        end
    end
end

-- Not part of the mining loop: walk back to the shaft bottom through the grid's own tunnels
-- (no ore checks, no commands), so the caller's nav.goTo(home) is a straight climb.
local function rawLine(axis, target)
    for _ = 1, math.abs(target - axisPos(axis)) + 1 do
        local c = axisPos(axis)
        if c == target then return true end
        local ok, reason, detail = safeMove(axisDir(axis, target > c))
        if not ok then return false, reason, detail end
    end
    return axisPos(axis) == target, "not advancing"
end

-- Returns true, or false, reason, detail. reason is a nav reason ("no_fuel", "unbreakable",
-- "timeout", ...) or "stuck" when a protected block (chest, computer, ...) is in the way;
-- detail then names the block and where. Protected blocks are never dug.
function mine.retreat()
    if armyOn and armyRetreat then return armyRetreat() end
    if type(st.job) == "table" then geom() else ensureJob() end
    local f, r = frame(st.pos)
    if f == 0 and r == 0 then return true end
    local legs = {}
    if st.pos.y ~= targetY() then legs[#legs + 1] = { "y", targetY() } end
    local m = nearestMain(r)
    if f ~= 1 and m ~= r and f > 1 then legs[#legs + 1] = { "r", m } end
    legs[#legs + 1] = { "f", 1 }
    legs[#legs + 1] = { "r", 0 }
    legs[#legs + 1] = { "f", 0 }
    for _, leg in ipairs(legs) do
        local ok, reason, detail = rawLine(leg[1], leg[2])
        if not ok then
            if reason == "protected" then return false, "stuck", detail end
            return false, reason, detail
        end
    end
    return true
end

-- Blocks walked by mine.retreat + nav.goTo(home) from `p` (default st.pos): back through the
-- tunnels to the shaft, then straight up. For the current position while vein mining, the
-- backtrack along the vein path is added. nil before mine.init or when the position is lost
-- (callers then fall back to the Manhattan distance). Never less than the Manhattan distance.
function mine.routeHomeLength(p)
    if not ready or type(st) ~= "table" or type(st.pos) ~= "table" or type(st.home) ~= "table" then
        return nil
    end
    if st.lost or type(st.job) ~= "table" or type(cfg) ~= "table" then return nil end
    if armyOn and armyRouteLen then return armyRouteLen(p) end
    geom()
    local extra = 0
    if not p then
        p = st.pos
        if veinFrom and veinPath then extra, p = #veinPath, veinFrom end
    end
    local T, h = targetY(), st.home
    local f, r = frame(p)
    local n
    if f == 0 and r == 0 then
        n = math.abs(p.y - h.y)
    else
        n = math.abs(p.y - T)
        local m = nearestMain(r)
        if f ~= 1 and m ~= r and f > 1 then
            n = n + math.abs(r - m)
            r = m
        end
        n = n + math.abs(f - 1) + math.abs(r) + 1 + math.abs(T - h.y)
    end
    local manhattan = math.abs(p.x - h.x) + math.abs(p.y - h.y) + math.abs(p.z - h.z)
    return math.max(n, manhattan) + extra
end

-- Is world cell p dug by work this job has already completed, per the saved st.job? Used by
-- nav.recover (opts.isKnownOpen) to settle a crash without GPS. Counts only the planned grid at
-- the level the job started (geom.y == TARGET_Y), never vein cells or cells not reached yet,
-- and nothing after a world rollback (st.job.noGrid). Conservative: false = unknown.
-- job.step lags the turtle (saved with snapshots), so it never claims too much.
function mine.isKnownOpen(p)
    if not ready or type(st) ~= "table" or type(st.job) ~= "table" or type(p) ~= "table" then
        return false
    end
    local job, g = st.job, st.job.geom
    if job.noGrid or type(job.corridor) ~= "number" or type(g) ~= "table" or not g.bl then return false end
    if g.y == nil or g.y ~= targetY() or p.y ~= g.y then return false end
    local c, b, s = job.corridor, job.branch or 0, job.step or 0
    local sideR = job.side == "R"
    local started = b > 0 or sideR or s > 0          -- current corridor's main was reached
    if c == 0 and not started then return false end
    local w, nb = 2 * g.bl + g.sp, math.floor((g.ml - 1) / g.sp)
    local f, r = frame(p)
    if f == 0 and r == 0 then return true end         -- shaft bottom
    local spineEnd = started and c * w or (c - 1) * w
    if f == 1 and r >= 0 and r <= spineEnd then return true end
    local ci = math.floor(r / w + 0.5)
    if ci < 0 or ci > c or (ci == c and not started) then return false end
    local off = r - ci * w
    local mainTo = g.ml
    if ci == c then
        if b < nb and (sideR or s > 0) then mainTo = 1 + (b + 1) * g.sp
        elseif b > 0 then mainTo = 1 + math.min(b, nb) * g.sp
        else mainTo = 1 end
    end
    if off == 0 then return f >= 1 and f <= mainTo end
    local dist = math.abs(off)
    if dist > g.bl or f < 1 + g.sp or (f - 1) % g.sp ~= 0 then return false end
    local bi = (f - 1) / g.sp - 1
    if bi >= nb then return false end
    if ci < c or bi < b then return true end
    if bi > b then return false end
    if off < 0 then return sideR or dist <= s end     -- side L (-R) is walked first
    return sideR and dist <= s
end

-- ------------------------------------------------------------------ army mode
-- Station frame (docs/ARMY_PLAN.md): home = station spot S, F = homeFacing. Shaft 1 is the column (f=1, r=0),
-- shaft 2 (f=1, r=1); the level's spine runs along R at f=2; corridor c has its main at r=c*W (f=2..1+ml);
-- branch b of side L/R sits at f=2+(b+1)*sp. Shared lanes are acquired through ctl.lane(segs, dir) /
-- ctl.unlane(segs) (miner/group.lua); outbound trips are "down", return trips "up". Without those hooks
-- (or without an army) none of this runs.

local held = {}   -- segment keys currently granted to us

local function lane(segs, dir)
    if #segs == 0 then return true end
    if not (ctl and ctl.lane) then return true end
    local ok, why = ctl.lane(segs, dir)
    if ok then for _, k in ipairs(segs) do held[k] = true end end
    return ok, why
end

local function unlane(segs)
    if not (ctl and ctl.unlane) then return end
    local out = {}
    for _, k in ipairs(segs) do if held[k] then held[k] = nil; out[#out + 1] = k end end
    if #out > 0 then pcall(ctl.unlane, out) end
end

local function unlaneAll()
    local out = {}
    for k in pairs(held) do out[#out + 1] = k end
    unlane(out)
end

local function cat(...)
    local out = {}
    for _, l in ipairs({ ... }) do for _, v in ipairs(l) do out[#out + 1] = v end end
    return out
end

local function seg16(v) return math.floor(v / 16) end
local function shaftSegs(k, y)
    local out = {}
    for i = 0, seg16(st.home.y - 1 - y) do out[#out + 1] = "s" .. k .. ":" .. i end
    return out
end
local function spineSegs(T, r1, r2)
    local out = {}
    for j = seg16(math.min(r1, r2)), seg16(math.max(r1, r2)) do out[#out + 1] = "sp" .. T .. ":" .. j end
    return out
end
local function mainSegs(T, c, f)
    local out = {}
    for i = 0, seg16(f - 2) do out[#out + 1] = "m" .. T .. ":" .. c .. ":" .. i end
    return out
end

local function aGeom() return aj or (armyInfo and armyInfo.geom) or { bl = 32, sp = 3, ml = 64 } end
local function aW() local g = aGeom(); return 2 * g.bl + g.sp end
local function aNearest(r) local w = aW(); return math.floor(r / w + 0.5) * w end
local function aBF() return 2 + (aj.b + 1) * aj.sp end
local function aRC() return aj.c * aW() end

-- reason from a failed lane request -> signal
local function laneSig(why)
    if why == "stop" then return "stop", "command" end
    return "return", "command"
end

-- Walk legs {axis, target, rel={segs}, after=fn}, with ore checks (lineTo).
local function walk(legs)
    for _, leg in ipairs(legs) do
        local sig, why = lineTo(leg[1], leg[2])
        if sig then unlaneAll(); return sig, why end
        if leg.rel then unlane(leg.rel) end
        if leg.after then leg.after() end
    end
    return nil
end

function mine.armyMode(on)
    armyOn = on and true or false
    if not armyOn then aj = nil; held = {} end
end

function mine.armyInfo(info) armyInfo = info end

-- Set (or clear) the current claim: {key, geom={bl,sp,ml}, near={"x,y,z",...}}
function mine.armyJob(job)
    if not job then aj = nil; return end
    local y, c, b, side = tostring(job.key):match("^(%-?%d+):(%-?%d+):(%d+):([LR])$")
    if not y then aj = nil; return end
    local g = job.geom or {}
    aj = { key = job.key, y = tonumber(y), c = tonumber(c), b = tonumber(b), side = side,
        bl = g.bl, sp = g.sp, ml = g.ml, near = {} }
    for _, k in ipairs(job.near or {}) do aj.near[k] = true end
end

function mine.armyResult()
    local o = armyOres
    armyOres = {}
    return { ores = o }
end

armyStart = function()
    local T, f, r
    if aj then T, f, r = aj.y, aBF(), aRC()
    else
        T = armyInfo and armyInfo.deepest or (st.home.y - 30)
        f, r = 2, 0
    end
    return mine.toWorld(f, r, T), FD()
end

armyRouteLen = function(p)
    local extra = 0
    if not p then
        p = st.pos
        if veinFrom and veinPath then extra, p = #veinPath, veinFrom end
    end
    local f, r = frame(p)
    local h = st.home
    local n
    if f <= 1 then
        n = math.abs(p.y - h.y) + 2
    else
        local m = aNearest(r)
        n = (h.y - p.y) + math.abs(f - 2) + math.abs(r - m) + math.abs(m) + 3
    end
    local manhattan = math.abs(p.x - h.x) + math.abs(p.y - h.y) + math.abs(p.z - h.z)
    return math.max(n, manhattan) + extra
end

-- Out: station spot / shaft -> start of the claimed branch, under "down" lanes.
local function aOut()
    local T, fb, rc = aj.y, aBF(), aRC()
    local f, r = frame(st.pos)
    local _, sign = sideDir(aj.side)
    if st.pos.y == T and f == fb and (r - rc) * sign >= 0 and math.abs(r - rc) <= aj.bl then return nil end
    if st.pos.y > T then
        local shaft, spine, main = shaftSegs(1, T), spineSegs(T, 0, rc), mainSegs(T, aj.c, fb)
        local ok, why = lane(cat(shaft, spine, main), "down")
        if not ok then return laneSig(why) end
        aj.mainSegs = main
        local legs = {}
        if f == 0 then
            legs[#legs + 1] = { "f", 1, after = function() if ctl and ctl.unstation then pcall(ctl.unstation) end end }
        end
        legs[#legs + 1] = { "y", T }
        legs[#legs + 1] = { "f", 2, rel = shaft }
        legs[#legs + 1] = { "r", rc }
        legs[#legs + 1] = { "f", fb, rel = spine }
        return walk(legs)
    end
    -- already at the level (resumed in the grid): same route logic as solo, spine row f=2
    local m = aNearest(r)
    local sig, why
    if f ~= 2 and m ~= r then
        sig, why = lineTo("r", m)
        if sig then return sig, why end
        r = m
    end
    if r ~= rc then
        sig, why = lineTo("f", 2)
        if sig then return sig, why end
        sig, why = lineTo("r", rc)
        if sig then return sig, why end
    end
    return lineTo("f", fb)
end

function mine.runBranch(job)
    mine.armyJob(job)
    if not aj then return "stuck", "bad claim key " .. tostring(job and job.key) end
    local sig, why = aOut()
    if sig then return sig, why end
    local rc = aRC()
    local _, sign = sideDir(aj.side)
    local first = true
    sig, why = lineTo("r", rc + sign * aj.bl, function()
        if first then first = false; if aj.mainSegs then unlane(aj.mainSegs) end end
        local _, r2 = frame(st.pos)
        if type(st.army) == "table" then st.army.step = math.abs(r2 - rc) end
    end)
    if sig then return sig, why end
    unlane(aj.mainSegs or {})
    return "done", aj.key
end

-- Dig the second shaft (column f=1, r=1) from the station down to `deepest`, climb back to the spot.
function mine.digShaft(deepest)
    local f = frame(st.pos)
    local sig, why
    if st.pos.y == st.home.y then
        if f == 0 then sig, why = lineTo("f", 1); if sig then return sig, why end end
        sig, why = lineTo("r", 1)
        if sig then return sig, why end
    end
    sig, why = lineTo("y", deepest)
    if sig then return sig, why end
    local ok, reason, detail = rawLine("y", st.home.y)
    if ok then ok, reason, detail = rawLine("r", 0) end
    if ok then ok, reason, detail = rawLine("f", 0) end
    if not ok then return "stuck", tostring(detail or reason) end
    return "done"
end

-- Return: branch/main/spine/shaft back to the station spot under "up" lanes (shaft 2 once it exists).
-- Returns true | false, reason, detail (like the solo retreat).
armyRetreat = function()
    local H0 = st.home.y
    local f, r = frame(st.pos)
    local function raw(axis, target)
        local ok, reason, detail = rawLine(axis, target)
        if not ok then
            if reason == "protected" then return false, "stuck", detail end
            return false, reason, detail
        end
        return true
    end
    local function station() if ctl and ctl.station then return ctl.station() end end
    local function laneFail(why)
        unlaneAll()
        return false, "stuck", "lane: " .. tostring(why)
    end
    if st.pos.y >= H0 then
        for _, leg in ipairs({ { "r", 0 }, { "f", 0 } }) do
            local ok, a, b = raw(leg[1], leg[2]); if not ok then return false, a, b end
        end
        return true
    end
    local legs, shaftSeg, spine, main = {}, {}, {}, {}
    local k = (type(st.army) == "table" and st.army.shaft2) and 2 or 1
    local T = st.pos.y
    if f > 1 then
        if aj and T ~= aj.y then
            local ok, a, b = raw("y", aj.y); if not ok then return false, a, b end
            T = aj.y
        end
        local m = aNearest(r)
        if f > 2 and r ~= m and math.abs(r - m) > 1 then
            local nr = m + (r > m and 1 or -1)
            local ok, a, b = raw("r", nr); if not ok then return false, a, b end
            r = nr
        end
        local c = m / aW()
        local got = false
        for attempt = 1, 2 do
            local r0 = (k == 2) and 1 or 0
            shaftSeg = shaftSegs(k, T)
            spine = spineSegs(T, f > 2 and m or r, r0)
            main = f > 2 and mainSegs(T, c, f) or {}
            station()
            local ok, why = lane(cat(shaftSeg, spine, main), "up")
            if ok then got = true; break end
            if why == "use_shaft2" and attempt == 1 then
                k = 2
                if type(st.army) == "table" then st.army.shaft2 = true end
            else
                return laneFail(why)
            end
        end
        if not got then return laneFail("denied") end
        local r0 = (k == 2) and 1 or 0
        legs = { { "r", f > 2 and m or r }, { "f", 2 }, { "r", r0, rel = main }, { "f", 1, rel = spine },
            { "y", H0 }, { "aside" }, { "r", 0 }, { "f", 0, rel = shaftSeg } }
    else
        -- inside a shaft column
        local kk = (r == 1) and 2 or 1
        shaftSeg = shaftSegs(kk, T)
        station()
        local ok, why = lane(shaftSeg, "up")
        if not ok then return laneFail(why) end
        legs = { { "y", H0 }, { "aside" }, { "r", 0 }, { "f", 0, rel = shaftSeg } }
    end
    for _, leg in ipairs(legs) do
        if leg[1] == "aside" then
            -- top of the shaft: wait for the station spot standing in (1,1), not in the way of whoever leaves
            local waited = 0
            while true do
                if ctl and ctl.stationAside then ctl.stationAside(function() rawLine("r", 1) end) end
                local _, rr = frame(st.pos)
                if rr ~= 0 then
                    local ok = rawLine("r", 0)
                    if not ok then break end
                end
                -- is a turtle standing on the station spot (not in the queue, e.g. it came up on its slot)?
                local present, data = look((FD() + 2) % 4)
                if not (present and isTurtleBlock(data)) then break end
                rawLine("r", 1)
                waited = waited + 3
                sleep(3)
                if ctlCheck() == "stop" or waited > 600 then break end
            end
        else
            local ok, a, b = raw(leg[1], leg[2])
            if not ok then unlaneAll(); return false, a, b end
            if leg.rel then unlane(leg.rel) end
        end
    end
    unlaneAll()
    return true
end

return mine
