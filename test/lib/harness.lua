-- Version: 1.0.1
-- Scenario helpers: pass/fail/skip plumbing, crash predicates, a fake TMINER
-- server (virtual rednet node), truth-vs-belief watchers and the standard
-- "turtle at home with a chest behind it" setup.

local H = {}

local sim, ROOT
local notes = {}

function H.init(s, root)
    sim, ROOT = s, root
end

---------------------------------------------------------------------------
-- result plumbing
---------------------------------------------------------------------------
function H.fail(msg, ...)
    if select("#", ...) > 0 then msg = string.format(msg, ...) end
    error({ hfail = msg }, 0)
end

function H.check(cond, msg, ...)
    if not cond then H.fail(msg, ...) end
    return cond
end

function H.skip(msg) error({ hskip = msg }, 0) end

function H.note(msg) notes[#notes + 1] = msg end

local function minerDir()
    return os.getenv("SIM_MINER_DIR") or (ROOT .. "/miner")
end

function H.fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

function H.has(mod)
    return H.fileExists(minerDir() .. "/" .. mod .. ".lua")
end

-- Returns true if all modules exist; otherwise records a note and returns false.
function H.need(mods, what)
    for _, m in ipairs(mods) do
        if not H.has(m) then
            H.note((what or "part") .. " skipped: miner/" .. m .. ".lua missing")
            return false
        end
    end
    return true
end

H.ALL = { "config", "state", "nav", "inv", "mine", "net", "miner" }

function H.runScenario(name, scen)
    notes = {}
    for _, m in ipairs(scen.needs or {}) do
        if not H.has(m) then return "SKIP", "miner/" .. m .. ".lua missing" end
    end
    if scen.needsFile and not H.fileExists(ROOT .. "/" .. scen.needsFile) then
        return "SKIP", scen.needsFile .. " missing"
    end
    sim.reset()
    local ok, err = xpcall(function() return scen.run(sim, H) end, function(e)
        if type(e) == "table" then return e end
        return { crash = tostring(e) .. "\n" .. debug.traceback("", 2) }
    end)
    local extra = #notes > 0 and (" [" .. table.concat(notes, "; ") .. "]") or ""
    if ok then
        return "PASS", ((type(err) == "string" and err) or (scen.title or "")) .. extra
    end
    if err.hskip then return "SKIP", err.hskip .. extra end
    if err.hfail then return "FAIL", err.hfail .. extra end
    return "FAIL", "test harness error: " .. tostring(err.crash) .. extra
end

---------------------------------------------------------------------------
-- small utils
---------------------------------------------------------------------------
function H.fmtPos(p)
    if type(p) ~= "table" then return tostring(p) end
    return string.format("(%s,%s,%s)", tostring(p.x), tostring(p.y), tostring(p.z))
end

function H.samePos(a, b)
    return type(a) == "table" and type(b) == "table" and a.x == b.x and a.y == b.y and a.z == b.z
end

function H.dist(a, b)
    return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

H.DIRS = { [0] = { x = 0, z = -1 }, [1] = { x = 1, z = 0 }, [2] = { x = 0, z = 1 }, [3] = { x = -1, z = 0 } }

-- rotate an (x,z) vector clockwise k quarter turns (north -> east)
function H.rot(x, z, k)
    for _ = 1, (k % 4) do x, z = -z, x end
    return x, z
end

-- Frame: map a turtle-believed position/facing to world coords.
-- gps=true: identity. gps=false: relative frame with home {0,0,0} facing 0 at the
-- world position/facing the turtle had at first boot.
-- worldY=true: the relative frame's y is already world y (miner with HOME_Y set).
function H.frame(homeWorld, homeFacing, gps, worldY)
    local fr = {}
    function fr.toWorld(p)
        if gps then return { x = p.x, y = p.y, z = p.z } end
        local x, z = H.rot(p.x, p.z, homeFacing)
        return { x = homeWorld.x + x, y = worldY and p.y or (homeWorld.y + p.y), z = homeWorld.z + z }
    end
    function fr.facingToWorld(f)
        if gps then return f end
        return (f + homeFacing) % 4
    end
    -- home frame (f = along homeFacing, r = to the right), relative to home
    function fr.toGrid(wp)
        local F, R = H.DIRS[homeFacing], H.DIRS[(homeFacing + 1) % 4]
        local dx, dz = wp.x - homeWorld.x, wp.z - homeWorld.z
        return dx * F.x + dz * F.z, dx * R.x + dz * R.z, wp.y
    end
    return fr
end

function H.writeSettings(t, tbl)
    local s = {}
    local old = t.fs:read(".settings")
    if old then s = sim.textutils.unserialize(old) or {} end
    for k, v in pairs(tbl) do s["tminer." .. k] = v end
    t.fs:write(".settings", sim.textutils.serialize(s))
end

---------------------------------------------------------------------------
-- crash predicates: build crashAt functions
---------------------------------------------------------------------------
-- crash on the nth event matching pred (n default 1); afterwards never again
function H.crashOn(pred, n)
    n = n or 1
    local seen, fired = 0, false
    local f = {}
    setmetatable(f, { __call = function(_, evt)
        if fired then return false end
        if pred(evt) then
            seen = seen + 1
            if seen >= n then fired = true; f.event = evt; return true end
        end
        return false
    end })
    f.fired = function() return fired end
    return f
end

function H.isTurtleOp(op, when)
    return function(e) return e.kind == "turtle" and e.op == op and (when == nil or e.when == when) and (e.when ~= "after" or e.ok) end
end

-- journal record write: tag "I" or "D"; op letter optional (for "I")
function H.isJournalWrite(tag, opLetter, pathPattern)
    return function(e)
        if e.kind ~= "fs_close" or not e.path:find(pathPattern or "tm_journal") then return false end
        local d = e.data or ""
        local last = d:match("([^\n]+)\n?$") or d
        if last:sub(1, 1) ~= tag then return false end
        if opLetter and not last:match("^" .. tag .. " " .. opLetter .. "%f[%s]") then return false end
        return true
    end
end

function H.isClose(pathPattern)
    return function(e) return e.kind == "fs_close" and e.path:find(pathPattern) ~= nil end
end

function H.isMove(toPattern)
    return function(e) return e.kind == "fs_move" and e.to:find(toPattern) ~= nil end
end

---------------------------------------------------------------------------
-- fake TMINER server (virtual rednet node, no coroutine needed)
---------------------------------------------------------------------------
function H.server(opts)
    opts = opts or {}
    local srv = {
        id = opts.id or 100,
        boot = sim.BASE_EPOCH,
        seq = 0,
        msgs = {},          -- every TMINER message received {time, from, msg}
        status = {},        -- latest status per turtle id
        statuses = {},      -- list per turtle id
        acks = {},          -- cmd id -> list of {from, ok, err}
        homes = {},
        phases = {},        -- turtle id -> list of {time, phase, reason}
        hellos = {},
        events = {},
        onStatus = nil,     -- optional callback(from, msg)
    }
    local function envelope(kind, to, body)
        srv.seq = srv.seq + 1
        local m = { v = 1, kind = kind, from = srv.id, to = to, boot = srv.boot, seq = srv.seq,
                    ts = math.floor(sim.BASE_EPOCH + sim.now * 1000), hops = 0 }
        for k, v in pairs(body or {}) do m[k] = v end
        return m
    end
    function srv.send(to, kind, body, broadcast)
        local m = envelope(kind, to, body)
        local toId = to
        if broadcast or type(to) ~= "number" then toId = nil end
        sim.net.inject(srv.id, toId, m, "TMINER")
        return m
    end
    function srv.cmd(target, cmd, params, broadcast)
        local id = "c" .. srv.seq + 1 .. "_" .. cmd
        if broadcast == nil then broadcast = true end
        srv.send(target, "cmd", { id = id, cmd = cmd, params = params or {} }, broadcast)
        return id
    end
    function srv.fleet(turtles)
        srv.send("all", "fleet", { turtles = turtles, server = { id = srv.id, label = "simsrv" } }, true)
    end
    function srv.lastStatus(id) return srv.status[id] end
    function srv.phaseSeen(id, phase)
        for _, p in ipairs(srv.phases[id] or {}) do if p.phase == phase then return p end end
        return nil
    end
    function srv.phaseList(id)
        local r = {}
        for _, p in ipairs(srv.phases[id] or {}) do r[#r + 1] = p.phase end
        return table.concat(r, ">")
    end
    sim.net.addNode(srv.id, function(from, msg, protocol)
        if protocol ~= "TMINER" or type(msg) ~= "table" then return end
        srv.msgs[#srv.msgs + 1] = { time = sim.now, from = from, msg = msg }
        local k = msg.kind
        if k == "status" then
            srv.status[from] = msg
            srv.statuses[from] = srv.statuses[from] or {}
            table.insert(srv.statuses[from], msg)
            srv.phases[from] = srv.phases[from] or {}
            local ph = srv.phases[from]
            if #ph == 0 or ph[#ph].phase ~= msg.phase or ph[#ph].reason ~= msg.reason then
                ph[#ph + 1] = { time = sim.now, phase = msg.phase, reason = msg.reason }
            end
            if srv.onStatus then srv.onStatus(from, msg) end
        elseif k == "ack" then
            srv.acks[msg.id] = srv.acks[msg.id] or {}
            table.insert(srv.acks[msg.id], { from = from, ok = msg.ok, err = msg.err })
        elseif k == "home_get" then
            local h = srv.homes[from]
            srv.send(from, "home", h and { found = true, home = h.home, homeFacing = h.homeFacing, gps = h.gps }
                or { found = false }, false)
        elseif k == "home_save" then
            srv.homes[from] = { home = msg.home, homeFacing = msg.homeFacing, gps = msg.gps }
        elseif k == "hello" then
            srv.hellos[#srv.hellos + 1] = { time = sim.now, from = from, msg = msg }
        elseif k == "event" then
            srv.events[#srv.events + 1] = { time = sim.now, from = from, msg = msg }
        end
    end)
    return srv
end

---------------------------------------------------------------------------
-- watchers: compare what the turtle reports with the truth
---------------------------------------------------------------------------
-- opts: frame (H.frame), skipPhases (set), home (world pos, for strand check)
function H.watch(t, srv, opts)
    local wt = { violations = {}, strands = {}, statusChecked = 0 }
    local skip = opts.skipPhases or { BOOT = true, RECOVER = true, NEEDS_HELP = true, ERROR = true }
    local fr = opts.frame
    local prev = srv.onStatus
    srv.onStatus = function(from, msg)
        if prev then prev(from, msg) end
        if from ~= t.id or skip[msg.phase] or type(msg.pos) ~= "table" then return end
        wt.statusChecked = wt.statusChecked + 1
        local wp = fr.toWorld(msg.pos)
        local wf = msg.facing and fr.facingToWorld(msg.facing)
        local posOk = H.samePos(wp, t.pos) or H.samePos(wp, t.prevPos)
        local facOk = wf == nil or wf == t.facing or wf == t.prevFacing
        if not posOk or not facOk then
            wt.violations[#wt.violations + 1] = string.format(
                "t=%.1f phase %s: reports pos %s facing %s (world %s/%s), truth %s facing %d",
                sim.now, tostring(msg.phase), H.fmtPos(msg.pos), tostring(msg.facing), H.fmtPos(wp), tostring(wf),
                H.fmtPos(t.pos), t.facing)
        end
    end
    if opts.home then
        sim.addHook(t, function(e)
            if t.fuel == "unlimited" then return end
            if e.op == "forward" or e.op == "back" or e.op == "up" or e.op == "down" then
                local d = H.dist(t.pos, opts.home)
                if t.fuel < d then
                    wt.strands[#wt.strands + 1] = string.format("t=%.1f fuel %d < %d blocks from home at %s",
                        sim.now, t.fuel, d, H.fmtPos(t.pos))
                end
            end
        end)
    end
    function wt.assertClean()
        H.check(#wt.violations == 0, "reported position/facing disagrees with world (%d times), first: %s",
            #wt.violations, wt.violations[1] or "")
        H.check(#wt.strands == 0, "turtle stranded (fuel below distance home %d times), first: %s",
            #wt.strands, wt.strands[1] or "")
    end
    return wt
end

---------------------------------------------------------------------------
-- standard full-miner setup
---------------------------------------------------------------------------
-- opts: id, label, gps, home (world pos), facing, fuel, inventory, settings (overrides),
--       chest (dump contents), chestSize, fuelChest (contents or nil), world (opts), srv (existing server)
function H.minerSetup(opts)
    opts = opts or {}
    local home = opts.home or { x = 0, y = 0, z = 0 }
    local facing = opts.facing or 0
    local w = opts.w or sim.world(opts.world)
    local F = H.DIRS[facing]
    local L = H.DIRS[(facing + 3) % 4]
    local ctx = { w = w, home = home, facing = facing }
    -- world position of a side of the home cell (relative to the home facing)
    local function sidePos(side)
        local d
        if side == "top" then return { x = home.x, y = home.y + 1, z = home.z } end
        if side == "bottom" then return { x = home.x, y = home.y - 1, z = home.z } end
        if side == "front" then d = F
        elseif side == "back" then d = H.DIRS[(facing + 2) % 4]
        elseif side == "left" then d = L
        else d = H.DIRS[(facing + 1) % 4] end
        return { x = home.x + d.x, y = home.y, z = home.z + d.z }
    end
    ctx.sidePos = sidePos
    -- dump chest: behind by default (opts.chestSide); opts.chestName for other blocks
    ctx.chestPos = sidePos(opts.chestSide or "back")
    w:chest(ctx.chestPos.x, ctx.chestPos.y, ctx.chestPos.z, opts.chest or {},
        { size = opts.chestSize, name = opts.chestName })
    if opts.fuelChest then
        -- default on top; opts.fuelChestSide = "left" puts it behind the equipped modem,
        -- where peripheral can't see it (as in CC) and only inspect finds it
        ctx.fuelChestPos = sidePos(opts.fuelChestSide or "top")
        w:chest(ctx.fuelChestPos.x, ctx.fuelChestPos.y, ctx.fuelChestPos.z, opts.fuelChest)
    end
    if opts.gps and not opts.enclosedHome then
        -- GPS facing calibration (forward, else back, else up+forward) needs room: open
        -- the two cells above home and the one in front of that, like a surface base.
        w:set(home.x, home.y + 1, home.z, "air")
        w:set(home.x + F.x, home.y + 1, home.z + F.z, "air")
    end
    local t = sim.turtle(w, { id = opts.id or 1, label = opts.label or ("T" .. (opts.id or 1)), pos = home,
        facing = facing, fuel = opts.fuel or 5000, gps = opts.gps, inventory = opts.inventory })
    t.computer.label = opts.label or ("T" .. t.id)
    ctx.t = t
    -- Without GPS the miner needs HOME_Y (the installer asks for it); TARGET_Y is world Y.
    local targetY = home.y - 6
    ctx.cfg = {
        TARGET_Y = targetY, BRANCH_LENGTH = 4, BRANCH_SPACING = 3, MAIN_LENGTH = 8, MAX_CORRIDORS = 2,
        VEIN_MAX = 16, FUEL_MARGIN = 20, FUEL_KEEP = 4, FUEL_TARGET = 2000, STATUS_INTERVAL = 10,
        AUTO_UPDATE = false, STUCK_TIMEOUT = 60, HELP_RETRY = 30, SNAPSHOT_EVERY = 100,
    }
    if not opts.gps then ctx.cfg.HOME_Y = home.y end
    for k, v in pairs(opts.settings or {}) do ctx.cfg[k] = v end
    H.writeSettings(t, ctx.cfg)
    ctx.worldTargetY = ctx.cfg.TARGET_Y
    ctx.srv = opts.srv or H.server()
    ctx.frame = H.frame(home, facing, opts.gps, true)
    ctx.watch = H.watch(t, ctx.srv, { frame = ctx.frame, home = home })
    function ctx.boot(bopts)
        bopts = bopts or {}
        bopts.background = true
        return sim.boot(t, { "miner" }, bopts)
    end
    function ctx.atHome() return H.samePos(t.pos, home) end
    function ctx.phase() local s = ctx.srv.status[t.id]; return s and s.phase end
    function ctx.reason() local s = ctx.srv.status[t.id]; return s and s.reason end
    return ctx
end

-- Run the scheduler until cond() or fail with a diagnostic.
function H.runUntil(ctx, cond, maxTime, what)
    local c = ctx.t.computer
    local r = sim.run({ untilFn = function()
        if not c.alive then return true end
        return cond()
    end, maxTime = maxTime or 3600 })
    if not c.alive and not cond() then
        H.fail("%s: miner stopped (%s) %s", what or "run", tostring(c.status),
            tostring(c.err or (c.crashEvent and c.crashEvent.kind) or ""):sub(1, 600))
    end
    if r.status ~= "until" then
        H.fail("%s: %s (%s); last phase %s reason %s; phases %s; turtle at %s fuel %s%s",
            what or "condition not reached", r.status, r.why or "",
            tostring(ctx.phase()), tostring(ctx.reason()), ctx.srv.phaseList(ctx.t.id):sub(-300),
            H.fmtPos(ctx.t.pos), tostring(ctx.t.fuel), H.diag(ctx))
    end
    return r
end

function H.diag(ctx)
    local c = ctx.t.computer
    local parts = {}
    if #c.readCalls > 0 then parts[#parts + 1] = "read() called" end
    if c.errors and #c.errors > 0 then parts[#parts + 1] = "printError: " .. c.errors[#c.errors]:sub(1, 200) end
    local s = ctx.srv.status[ctx.t.id]
    if s and s.lastError then parts[#parts + 1] = "lastError: " .. tostring(s.lastError):sub(1, 200) end
    if #parts == 0 then return "" end
    return "; " .. table.concat(parts, "; ")
end

-- Standard invariants for any full-miner run.
function H.commonChecks(ctx)
    local c = ctx.t.computer
    H.check(#c.readCalls == 0, "read() was called (blocking prompt): %s", c.readCalls[1] and c.readCalls[1].trace:sub(1, 300) or "")
    H.check(not ctx.srv.phaseSeen(ctx.t.id, "ERROR"), "turtle reported ERROR: %s", H.diag(ctx))
    ctx.watch.assertClean()
end

-- Which cells were dug at mining level, in home-frame grid coords.
function H.dugGrid(ctx, sinceIndex)
    local r = {}
    local w = ctx.w
    for i = sinceIndex or 1, #w.digLog do
        local d = w.digLog[i]
        if not d.rollback and d.by == ctx.t.id then
            local f, rr, y = ctx.frame.toGrid(d)
            r[#r + 1] = { f = f, r = rr, y = y, name = d.name, time = d.time, i = i }
        end
    end
    return r
end

---------------------------------------------------------------------------
-- nav-level driver / probe (exercise state.lua + nav.lua without miner.lua)
---------------------------------------------------------------------------
-- Driver: reads drv.cfg {gps, home, facing, ops={...}, keepGoing}; creates state if
-- none, then runs ops: f b u d l r (nav moves/turns), s (state.save), R (burn 1
-- item from slot 16 + state.logRefuel). Returns {results={{op,ok,why}}, pos, facing}.
H.DRIVER_SRC = [==[
local h = fs.open("drv.cfg", "r")
local cfg = textutils.unserialize(h.readAll())
h.close()
local state = require("state")
local nav = require("nav")
local st = state.load()
if not st then
    st = state.new(cfg.home, cfg.facing, cfg.gps)
    state.save(st)
end
nav.init(st, {
    shouldAbort = function() return false end,
    onMove = function() end,
    save = function() return state.save(st) end,
})
local results = {}
local NAV = { f = "forward", b = "back", u = "up", d = "down", l = "turnLeft", r = "turnRight" }
for i, op in ipairs(cfg.ops) do
    local ok, why
    if NAV[op] then
        ok, why = nav[NAV[op]]()
        if ok == nil and (op == "l" or op == "r") then ok = true end
    elseif op == "s" then
        ok = state.save(st)
        if ok == nil then ok = true end
    elseif op == "R" then
        turtle.select(16)
        ok, why = turtle.refuel(1)
        turtle.select(1)
        state.logRefuel(turtle.getFuelLevel())
    end
    results[#results + 1] = { op = op, ok = ok, why = why }
    if not ok and not cfg.keepGoing then break end
end
return { results = results, pos = st.pos, facing = st.facing }
]==]

H.PROBE_SRC = [==[
local state = require("state")
local nav = require("nav")
local st = state.load()
if not st then return { noState = true } end
nav.init(st, {
    shouldAbort = function() return false end,
    onMove = function() end,
    save = function() return state.save(st) end,
})
local ok, reason = nav.recover(st)
return { ok = ok, reason = reason, pos = st.pos, facing = st.facing, phase = st.phase, stReason = st.reason }
]==]

-- Set up a fresh world + turtle for driver/probe runs.
-- opts: gps, pos, facing, fuel, inventory, world(fn w), id
function H.navSetup(opts)
    opts = opts or {}
    local w = sim.world()
    local pos = opts.pos or (opts.gps and { x = 100, y = 10, z = -50 } or { x = 0, y = 0, z = 0 })
    local facing = opts.facing or (opts.gps and 1 or 0)
    local t = sim.turtle(w, { id = opts.id or 1, pos = pos, facing = facing, fuel = opts.fuel or 1000,
        gps = opts.gps, inventory = opts.inventory })
    if opts.world then opts.world(w, t) end
    t.fs:write("drv.lua", H.DRIVER_SRC)
    t.fs:write("probe.lua", H.PROBE_SRC)
    local ctx = { w = w, t = t, home = { x = pos.x, y = pos.y, z = pos.z }, facing = facing,
        frame = H.frame(pos, facing, opts.gps), gps = opts.gps }
    local stHome = opts.gps and ctx.home or { x = 0, y = 0, z = 0 }
    local stFacing = opts.gps and facing or 0
    function ctx.drive(ops, dopts)
        dopts = dopts or {}
        t.fs:write("drv.cfg", sim.textutils.serialize({ gps = opts.gps and true or false, home = stHome,
            facing = stFacing, ops = ops, keepGoing = dopts.keepGoing }))
        return sim.boot(t, { "drv" }, { crashAt = dopts.crashAt, maxTime = dopts.maxTime or 600 })
    end
    function ctx.probe()
        local r = sim.boot(t, { "probe" }, { maxTime = 300 })
        if r.status ~= "exit" then
            H.fail("probe (state.load + nav.recover) did not finish: %s %s", r.status, tostring(r.err or r.why))
        end
        return r.ret[1]
    end
    -- does the believed st.pos/facing match the world?
    function ctx.matches(p)
        local wp = ctx.frame.toWorld(p.pos)
        local wf = ctx.frame.facingToWorld(p.facing)
        return H.samePos(wp, t.pos) and wf == t.facing, wp, wf
    end
    return ctx
end

---------------------------------------------------------------------------
-- more helpers used by scenarios
---------------------------------------------------------------------------
-- condition: finished (DONE or IDLE) and physically at home
function H.doneAtHome(ctx, minDug)
    return function()
        local p = ctx.phase()
        return (p == "DONE" or p == "IDLE") and ctx.atHome() and #H.dugGrid(ctx) > (minDug or 20)
    end
end

-- set "f:r" -> true of cells dug at world y (or any y when nil)
function H.dugSet(ctx, y)
    local r = {}
    for _, d in ipairs(H.dugGrid(ctx)) do
        if y == nil or d.y == y then r[d.f .. ":" .. d.r] = true end
    end
    return r
end

function H.invCount(t, name)
    local n = 0
    for s = 1, 16 do
        local it = t.inv[s]
        if it and (name == nil or it.name == name or (type(name) == "function" and name(it.name))) then n = n + it.count end
    end
    return n
end

-- crash at the first write matching writePred after the nth successful turtle op
function H.crashOnWriteAfterOp(opName, n, writePred)
    local seen, armed, fired = 0, false, false
    return function(e)
        if fired then return false end
        if e.kind == "turtle" and e.op == opName and e.when == "after" and e.ok then
            seen = seen + 1
            if seen == n then armed = true end
        elseif armed and writePred(e) then
            fired = true
            return true
        end
        return false
    end
end

-- While waiting for help the miner must stay alive, stay in its phase and not
-- hammer the world (bounded turtle ops per minute).
function H.assertSettles(ctx, secs, maxPerMin)
    local phase = ctx.phase()
    local ops0, t0 = ctx.t.ops, sim.now
    sim.run({ maxTime = secs, untilFn = function() return not ctx.t.computer.alive end })
    H.check(ctx.t.computer.alive, "miner died while waiting for help: %s", tostring(ctx.t.computer.err))
    local perMin = (ctx.t.ops - ops0) / ((sim.now - t0) / 60)
    H.check(perMin < (maxPerMin or 60), "miner keeps hammering while %s (%.0f turtle ops/min)", tostring(phase), perMin)
    H.check(ctx.phase() == phase, "phase left %s without help: %s", tostring(phase), tostring(ctx.phase()))
end

-- Was block `name` (exact) dug by the turtle?
function H.wasDug(ctx, x, y, z)
    for _, d in ipairs(ctx.w.digLog) do
        if not d.rollback and d.x == x and d.y == y and d.z == z and d.by == ctx.t.id then return d end
    end
    return nil
end

-- world position for home-frame grid coords (f along homeFacing, r to the right)
function H.gridToWorld(ctx, f, r, y)
    local F, R = H.DIRS[ctx.facing], H.DIRS[(ctx.facing + 1) % 4]
    return { x = ctx.home.x + f * F.x + r * R.x, y = y, z = ctx.home.z + f * F.z + r * R.z }
end

function H.setGrid(ctx, f, r, y, name)
    local p = H.gridToWorld(ctx, f, r, y)
    ctx.w:set(p.x, p.y, p.z, name)
    return p
end

-- miner/config.lua DEFAULTS, loaded on the host (no CC APIs needed for that table)
function H.configDefaults()
    local path = (os.getenv("SIM_MINER_DIR") or (ROOT .. "/miner")) .. "/config.lua"
    local env = setmetatable({}, { __index = _G })
    local fn = assert(loadfile(path, "t", env))
    local ok, cfg = pcall(fn)
    H.check(ok and type(cfg) == "table" and cfg.DEFAULTS, "could not load miner/config.lua: %s", tostring(cfg))
    return cfg.DEFAULTS
end

function H.inList(list, name)
    for _, v in ipairs(list or {}) do if v == name then return true end end
    return false
end

-- Is home-frame cell (f, r) on the mining grid of INTERFACES.md (shaft, spine, mains, branches)?
function H.onGrid(ctx, f, r)
    local cfg = ctx.cfg
    local BL, BS = cfg.BRANCH_LENGTH, cfg.BRANCH_SPACING
    local W = 2 * BL + BS
    if f == 0 and r == 0 then return true end
    if f == 1 and r >= 0 then return true end
    if f < 1 then return false end
    local c = math.floor((r + W / 2) / W)
    if c < 0 then return false end
    if r == c * W then return true end
    if math.abs(r - c * W) <= BL and (f - 1) % BS == 0 and f > 1 then return true end
    return false
end

-- Digs that happened off the grid (vein excursions), grouped into contiguous runs.
function H.excursions(ctx)
    local runs, cur = {}, nil
    for _, d in ipairs(H.dugGrid(ctx)) do
        if H.onGrid(ctx, d.f, d.r) then
            if cur then runs[#runs + 1] = cur; cur = nil end
        else
            cur = cur or {}
            cur[#cur + 1] = d
        end
    end
    if cur then runs[#runs + 1] = cur end
    return runs
end

function H.droppedAwayFromHome(ctx, pred)
    local n = 0
    for _, d in ipairs(ctx.w.dropped) do
        if pred(d.name) and H.dist(d, ctx.home) > 2 then n = n + d.count end
    end
    return n
end

function H.notNeedsHelp(ctx)
    local nh = ctx.srv.phaseSeen(ctx.t.id, "NEEDS_HELP")
    H.check(not nh, "went NEEDS_HELP: %s", tostring(nh and nh.reason))
end

-- Model "the turtle has already mined a lot": the first time it is at least `dist`
-- blocks from home, fill empty slots with `name` until only `free` slots are left.
-- (Pre-filling at boot doesn't work: the miner unloads at home first.)
function H.fillWhenAway(ctx, name, free, dist)
    local done = false
    sim.addHook(ctx.t, function()
        if done or H.dist(ctx.t.pos, ctx.home) < (dist or 6) then return end
        done = true
        local empty = {}
        for s = 1, 16 do if not ctx.t.inv[s] then empty[#empty + 1] = s end end
        for i = 1, #empty - free do ctx.t.inv[empty[i]] = { name = name, count = 64 } end
    end)
end

---------------------------------------------------------------------------
-- mine/inv driver: run a snippet against the real modules without miner.lua
---------------------------------------------------------------------------
-- The prelude loads config/state/nav/inv/mine for a no-GPS turtle whose home is world
-- (0,0,0) facing north (so the relative frame is the world frame), puts it at drv.cfg's
-- pos/facing and inits every module. The body sees: cfg, st, state, nav, inv, mine, ctlLog.
-- ctl.check() calls drv.cfg's onCheck snippet (string, may be nil) and logs
-- {pos, need = inv.fuelNeeded(st)} each time.
H.MINE_PRELUDE = [==[
local h = fs.open("drv.cfg", "r")
local dcfg = textutils.unserialize(h.readAll())
h.close()
local config = require("config")
local state = require("state")
local nav = require("nav")
local inv = require("inv")
local mine = require("mine")
local cfg = config.load()
local st = state.new({ x = 0, y = 0, z = 0 }, 0, false)
if dcfg.pos then st.pos = { x = dcfg.pos.x, y = dcfg.pos.y, z = dcfg.pos.z } end
st.facing = dcfg.facing or 0
if dcfg.job then st.job = dcfg.job end
st.phase = "MINING"
state.save(st)
nav.init(st, {
    shouldAbort = function() return false end,
    onMove = function() end,
    save = function() return state.save(st) end,
})
local ctlLog = {}
inv.init(st, cfg, nav)
if not dcfg.noMineInit then
    mine.init(st, cfg, nav, inv, { check = function()
        ctlLog[#ctlLog + 1] = { pos = { x = st.pos.x, y = st.pos.y, z = st.pos.z }, need = inv.fuelNeeded(st) }
        return nil
    end, event = function() end })
end
]==]

-- opts: pos (world), facing, fuel, inventory, settings, job, noMineInit, world(fn w), body (Lua
-- source run after the prelude; its return values come back as r.ret), crashAt, id.
-- Returns ctx with w, t, run().
function H.mineDriver(opts)
    opts = opts or {}
    local w = opts.w or sim.world()
    local pos = opts.pos or { x = 0, y = 0, z = 0 }
    local t = sim.turtle(w, { id = opts.id or 1, pos = pos, facing = opts.facing or 0,
        fuel = opts.fuel or 1000, inventory = opts.inventory })
    local cfg = { TARGET_Y = -6, HOME_Y = 0, BRANCH_LENGTH = 4, BRANCH_SPACING = 3, MAIN_LENGTH = 8,
        MAX_CORRIDORS = 2, VEIN_MAX = 16, FUEL_MARGIN = 20, FUEL_KEEP = 4, FUEL_TARGET = 2000 }
    for k, v in pairs(opts.settings or {}) do cfg[k] = v end
    H.writeSettings(t, cfg)
    if opts.world then opts.world(w, t) end
    local ctx = { w = w, t = t, cfg = cfg }
    function ctx.run(body, ropts)
        ropts = ropts or {}
        t.fs:write("drv.cfg", sim.textutils.serialize({ pos = pos, facing = opts.facing or 0,
            job = opts.job, noMineInit = opts.noMineInit }))
        t.fs:write("drv.lua", H.MINE_PRELUDE .. "\n" .. (body or opts.body or "return true"))
        local r = sim.boot(t, { "drv" }, { crashAt = ropts.crashAt, maxTime = ropts.maxTime or 600 })
        if r.status ~= "exit" and not ropts.crashAt then
            H.fail("driver did not finish: %s %s", tostring(r.status), tostring(r.err or r.why))
        end
        return r
    end
    -- open (air) every cell of a list of {x,y,z} or a box
    function ctx.open(x1, y1, z1, x2, y2, z2)
        for x = math.min(x1, x2), math.max(x1, x2) do
            for y = math.min(y1, y2), math.max(y1, y2) do
                for z = math.min(z1, z2), math.max(z1, z2) do w:set(x, y, z, "air") end
            end
        end
    end
    return ctx
end

return H
