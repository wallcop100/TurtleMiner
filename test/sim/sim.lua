-- Version: 1.0.1
-- Headless CC:Tweaked simulator: computers, turtles, a voxel world, an
-- in-memory rednet, and a single event scheduler on a simulated clock.
--
--   local sim = require("sim")
--   sim.reset()
--   local w = sim.world()
--   local t = sim.turtle(w, {id=1, pos={x=0,y=0,z=0}, facing=0, fuel=1000, gps=false})
--   local r = sim.boot(t, {"miner"}, {maxTime=600, crashAt=function(evt) ... end})
--   -- r.status: "exit" | "error" | "crashed" | "hung" | "shutdown" | "until" | "budget" | "idle"
--   local snap = sim.snapshot(t); ...; sim.rollback(t, snap)
--
-- Everything a program does is driven by events; sleep/timers/turtle actions
-- advance the simulated clock instantly, so long runs finish in milliseconds.

local World = require("world")
local FS = require("fs")
local Term = require("term")
local textutils = require("textutils")
local TurtleAPI = require("turtle_api")
local items = require("items")

local sim = {}
sim.REPO = sim.REPO or "."
sim.BASE_EPOCH = 1793000000000 -- ms; arbitrary fixed "real" date
sim.items = items
sim.textutils = textutils
sim.World = World
sim.FS = FS
sim.Term = Term
sim.deepcopy = World.deepcopy

local Computer = {}
Computer.__index = Computer

---------------------------------------------------------------------------
-- global state
---------------------------------------------------------------------------
function sim.reset()
    sim.now = 0
    sim.seq = 0
    sim.ticks = 0
    sim.pending = {}
    sim.computers = {}
    sim.byId = {}
    sim.worlds = {}
    sim.observers = {}
    sim.net = sim.newNet()
    sim.verbose = os.getenv("SIM_VERBOSE") ~= nil
    local seed = 12345
    items.rng = function(a, b)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return a + seed % (b - a + 1)
    end
end

function sim.copyPos(p)
    return { x = p.x, y = p.y, z = p.z }
end

function sim.log(...)
    if sim.verbose then io.stderr:write(string.format("[%8.2f] ", sim.now or 0), table.concat({ ... }, " "), "\n") end
end

-- observers see every check() event of every computer (used by harness)
function sim.observe(fn)
    sim.observers[#sim.observers + 1] = fn
end

---------------------------------------------------------------------------
-- event queue
---------------------------------------------------------------------------
function sim.queue(c, time, args)
    sim.seq = sim.seq + 1
    args.n = args.n or #args
    sim.pending[#sim.pending + 1] = { time = time, seq = sim.seq, c = c, boot = c.bootN, args = args }
end

local function popNext(deadline)
    local best, bi
    local i = 1
    while i <= #sim.pending do
        local e = sim.pending[i]
        if not e.c.alive or e.boot ~= e.c.bootN then
            table.remove(sim.pending, i)
        else
            if not best or e.time < best.time or (e.time == best.time and e.seq < best.seq) then
                best, bi = e, i
            end
            i = i + 1
        end
    end
    if not best then return nil, "idle" end
    if deadline and best.time > deadline then return nil, "budget" end
    table.remove(sim.pending, bi)
    return best
end

-- Yield the calling program until a turtle_response for a fresh task id.
function sim.waitTask(c, delay)
    c.nextTask = c.nextTask + 1
    local id = c.nextTask
    sim.queue(c, sim.now + delay, { "turtle_response", id, true, n = 3 })
    while true do
        c:guard()
        local ev = table.pack(coroutine.yield("turtle_response"))
        c:guard()
        if ev[1] == "turtle_response" and ev[2] == id then return end
    end
end

---------------------------------------------------------------------------
-- computers
---------------------------------------------------------------------------
function Computer:guard()
    if self.halted then
        while true do coroutine.yield() end
    end
end

function Computer:check(evt)
    evt.time = sim.now
    evt.computer = self
    for _, o in ipairs(sim.observers) do o(evt) end
    if self.crashAt and not self.halted then
        if self.crashAt(evt, self) then return true end
    end
    return false
end

function Computer:halt(evt, kind)
    self.halted = true
    self.haltKind = kind or "crashed"
    self.crashEvent = evt
    sim.log("computer", self.id, "halted:", self.haltKind, evt and (evt.kind .. " " .. tostring(evt.op or evt.path or "")) or "")
    while true do coroutine.yield() end
end

local function newComputer(opts)
    local c = setmetatable({}, Computer)
    c.id = opts.id or (#sim.computers + 1)
    assert(not sim.byId[c.id], "duplicate computer id " .. c.id)
    c.label = opts.label
    c.kind = opts.kind or "computer"
    c.fs = opts.fs or FS.new()
    c.peripherals = opts.peripherals or {}
    c.channels = {}
    c.rednetOpen = {}
    c.output = {}
    c.readCalls = {}
    c.status = "off"
    c.alive = false
    c.bootN = 0
    c.boots = 0
    c.nextTask = 0
    c.nextTimer = 0
    c.cancelled = {}
    c.gps = opts.gps or false
    c.pocket = opts.pocket or false
    local tw, th = 51, 19
    if c.kind == "turtle" then tw, th = 39, 13 end
    if c.pocket then tw, th = 26, 20 end
    if opts.termSize then tw, th = opts.termSize[1], opts.termSize[2] end
    c.term = Term.new(tw, th, { strict = opts.strictTerm, color = true })
    if opts.modem ~= false and c.kind ~= "turtle" then
        c.peripherals[opts.modem or "back"] = sim.modemPeripheral(c, opts.modem or "back", true)
    end
    sim.computers[#sim.computers + 1] = c
    sim.byId[c.id] = c
    return c
end

function sim.computer(opts)
    opts = opts or {}
    return newComputer(opts)
end

-- copy repo miner/*.lua into a computer's fs root (flat)
function sim.installMiner(c, dir)
    dir = dir or os.getenv("SIM_MINER_DIR") or (sim.REPO .. "/miner")
    local p = io.popen('ls "' .. dir .. '" 2>/dev/null')
    if not p then return end
    for name in p:lines() do
        if name:match("%.lua$") then
            local f = io.open(dir .. "/" .. name, "rb")
            if f then
                c.fs:write(name, f:read("a"))
                f:close()
            end
        end
    end
    p:close()
end

function sim.world(opts)
    opts = opts or {}
    opts.clock = function() return sim.now end
    local w = World.new(opts)
    sim.worlds[#sim.worlds + 1] = w
    return w
end

-- Turtle record + its computer.
-- opts: id, label, pos, facing, fuel (number|"unlimited"), fuelLimit, gps, inventory {[slot]={name,count}},
--       equip {left=, right=}, install (default true: copy miner/*.lua into fs)
function sim.turtle(w, opts)
    opts = opts or {}
    local t = {
        world = w,
        pos = sim.copyPos(opts.pos or { x = 0, y = 0, z = 0 }),
        facing = opts.facing or 0,
        fuel = opts.fuel or 1000,
        fuelLimit = opts.fuelLimit or 20000,
        gps = opts.gps or false,
        inv = {},
        selected = 1,
        equip = opts.equip or { left = "computercraft:wireless_modem_advanced", right = "minecraft:diamond_pickaxe" },
        ops = 0, moves = 0, digs = 0,
        opCounts = {},
        hooks = {},
        refuels = {},
    }
    if opts.modem == false then t.equip.left = nil end
    for s, it in pairs(opts.inventory or {}) do
        t.inv[s] = { name = it.name or it[1], count = it.count or it[2] or 1 }
    end
    local c = newComputer({ id = opts.id, label = opts.label, kind = "turtle", gps = t.gps, strictTerm = opts.strictTerm })
    c.turtle = t
    t.computer = c
    t.id = c.id
    t.fs = c.fs
    t.prevPos, t.prevFacing = sim.copyPos(t.pos), t.facing
    w:set(t.pos.x, t.pos.y, t.pos.z, "air")
    w.turtles[#w.turtles + 1] = t
    if opts.install ~= false then sim.installMiner(c) end
    return t
end

function sim.addHook(t, fn) t.hooks[#t.hooks + 1] = fn end

---------------------------------------------------------------------------
-- peripherals
---------------------------------------------------------------------------
function sim.modemPeripheral(c, side, wireless)
    local p = { types = { "modem" } }
    local m = {}
    local function chans()
        c.channels[side] = c.channels[side] or {}
        return c.channels[side]
    end
    function m.isWireless() return wireless end
    function m.open(ch) chans()[ch] = true end
    function m.close(ch) chans()[ch] = nil end
    function m.isOpen(ch) return chans()[ch] == true end
    function m.closeAll() c.channels[side] = {} end
    function m.transmit(ch, reply, msg)
        sim.net.transmit(c, ch, reply, msg)
    end
    function m.getNameLocal() return nil end
    function m.getNamesRemote() return {} end
    function m.isPresentRemote() return false end
    p.methods = m
    return p
end

local function chestPeripheral(w, x, y, z)
    local p = { types = { w:get(x, y, z), "inventory" } }
    local m = {}
    local function inv()
        local i = w:inventoryAt(x, y, z)
        if not i then error("Peripheral detached", 2) end
        return i
    end
    function m.size() return inv().size end
    function m.list()
        local r = {}
        for s, it in pairs(inv().slots) do r[s] = { name = it.name, count = it.count } end
        return r
    end
    function m.getItemDetail(s)
        local it = inv().slots[s]
        if not it then return nil end
        return { name = it.name, count = it.count, maxCount = items.maxStack(it.name), displayName = it.name }
    end
    function m.getItemLimit(s) return 64 end
    function m.pushItems() return 0 end
    function m.pullItems() return 0 end
    p.methods = m
    return p
end

local MODEM_UPGRADE = function(name) return name and name:find("modem") end

function sim.peripheralAt(c, side)
    local t = c.turtle
    if t then
        if (side == "left" or side == "right") and t.equip[side] then
            if MODEM_UPGRADE(t.equip[side]) then
                c._equipModems = c._equipModems or {}
                local cached = c._equipModems[side]
                if not cached then
                    cached = sim.modemPeripheral(c, side, not t.equip[side]:find("wired"))
                    c._equipModems[side] = cached
                end
                return cached
            end
            return nil
        end
        local which = side
        if side == "top" then which = "up" elseif side == "bottom" then which = "down" end
        if which == "front" or which == "back" or which == "left" or which == "right" or which == "up" or which == "down" then
            local x, y, z = TurtleAPI.offset(t, which)
            if t.world:inventoryAt(x, y, z) then return chestPeripheral(t.world, x, y, z) end
        end
        return nil
    end
    return c.peripherals[side]
end

---------------------------------------------------------------------------
-- network (in-memory rednet shared by all sim computers)
---------------------------------------------------------------------------
function sim.newNet()
    local net = { taps = {}, nodes = {}, log = {}, latency = 0.05 }
    -- tap(fromId, toId|nil, msg, protocol) is called for every message sent
    function net.tap(fn) net.taps[#net.taps + 1] = fn end
    -- virtual node: receives like a computer, onMessage(fromId, msg, protocol, toId)
    function net.addNode(id, onMessage)
        net.nodes[id] = onMessage
    end
    local function isOpen(c)
        for _, v in pairs(c.rednetOpen) do if v then return true end end
        return false
    end
    function net.deliver(fromId, toId, msg, protocol)
        net.log[#net.log + 1] = { time = sim.now, from = fromId, to = toId, msg = msg, protocol = protocol }
        for _, tap in ipairs(net.taps) do tap(fromId, toId, msg, protocol) end
        for _, c in ipairs(sim.computers) do
            if c.alive and not c.halted and isOpen(c) and (toId == nil and c.id ~= fromId or toId == c.id) then
                sim.queue(c, sim.now + net.latency, { "rednet_message", fromId, World.deepcopy(msg), protocol, n = 4 })
            end
        end
        for id, fn in pairs(net.nodes) do
            if (toId == nil and id ~= fromId) or toId == id then fn(fromId, World.deepcopy(msg), protocol, toId) end
        end
    end
    -- inject a message as if sent by fromId (virtual servers use this)
    function net.inject(fromId, toId, msg, protocol)
        net.deliver(fromId, toId, msg, protocol)
    end
    function net.transmit(c, ch, reply, msg)
        for _, o in ipairs(sim.computers) do
            if o ~= c and o.alive and not o.halted then
                for side, chs in pairs(o.channels) do
                    if chs[ch] then
                        sim.queue(o, sim.now + net.latency, { "modem_message", side, ch, reply, World.deepcopy(msg), 10, n = 6 })
                    end
                end
            end
        end
    end
    return net
end

---------------------------------------------------------------------------
-- boot / run
---------------------------------------------------------------------------
local Env -- lazily required (env requires sim)

local function loadSettings(c)
    c.settings = {}
    local s = c.fs:read(".settings")
    if s then
        local t = textutils.unserialize(s)
        if type(t) == "table" then c.settings = t end
    end
end

local HOOK_EVERY = 100000
local HOOK_LIMIT = 1000 -- * HOOK_EVERY instructions without yielding

function sim.hookCoroutine(c, co)
    debug.sethook(co, function()
        c.instr = (c.instr or 0) + 1
        if c.instr > HOOK_LIMIT then
            c.hung = true
            c.halted = true
            c.haltKind = "hung"
            error("SIM: computer " .. c.id .. " ran " .. (HOOK_LIMIT * HOOK_EVERY) .. " instructions without yielding (infinite loop?)", 0)
        end
    end, "", HOOK_EVERY)
end

local function start(c)
    Env = Env or require("env")
    c.bootN = c.bootN + 1
    c.boots = c.boots + 1
    c.halted = false
    c.haltKind = nil
    c.crashEvent = nil
    c.rebootReq, c.shutdownReq = false, false
    c.hung = false
    c.alive = true
    c.status = "running"
    c.err, c.ret = nil, nil
    c.filter = nil
    c.rednetOpen = {}
    c.channels = {}
    c._equipModems = nil
    c.cancelled = {}
    c.bootTime = sim.now
    loadSettings(c)
    c.term.setCursorPos(1, 1)
    local G = Env.build(sim, c)
    c.env = G
    local main
    local args = c.bootArgs
    if type(args) == "function" then
        main = function() return args(G, c) end
    else
        local fn, err = Env.program(sim, c, G, args[1], table.pack(table.unpack(args, 2)))
        if not fn then
            c.alive = false
            c.status = "error"
            c.err = err
            return
        end
        main = fn
    end
    c.co = coroutine.create(function()
        return table.pack(xpcall(main, debug.traceback))
    end)
    sim.hookCoroutine(c, c.co)
    sim.queue(c, sim.now, { "sim_start", n = 1 })
end

-- Resume a computer with one event.
local function deliver(c, args)
    if not c.alive then return end
    local name = args[1]
    if name ~= "sim_start" and c.filter ~= nil and c.filter ~= name and name ~= "terminate" then return end
    if name == "timer" and c.cancelled[args[2]] then return end
    c.instr = 0
    local res
    if name == "sim_start" then
        res = table.pack(coroutine.resume(c.co))
    else
        res = table.pack(coroutine.resume(c.co, table.unpack(args, 1, args.n)))
    end
    if c.rebootReq then
        sim.log("computer", c.id, "reboot")
        c.alive = false
        start(c)
        return
    end
    if c.shutdownReq then
        c.alive = false
        c.status = "shutdown"
        return
    end
    if c.halted then
        c.alive = false
        c.status = c.haltKind or "crashed"
        if c.hung then c.err = "ran too long without yielding (infinite loop?)" end
        return
    end
    if not res[1] then
        c.alive = false
        c.status = "error"
        c.err = tostring(res[2])
        return
    end
    if coroutine.status(c.co) == "dead" then
        c.alive = false
        local r = res[2]
        if r and r[1] then
            c.status = "exit"
            c.ret = table.pack(table.unpack(r, 2, r.n))
        else
            c.status = "error"
            c.err = r and tostring(r[2]) or "?"
        end
        return
    end
    c.filter = res[2]
end

-- Run the scheduler.
-- opts: stopOn (computer: stop when it is no longer alive), untilFn() -> bool,
--       maxTime (sim seconds from now, default 3600), maxTicks (events, default 500000)
-- returns {status=, time=, ticks=, err=, ret=, event=}
function sim.run(opts)
    opts = opts or {}
    local deadline = sim.now + (opts.maxTime or 3600)
    local maxTicks = sim.ticks + (opts.maxTicks or 500000)
    local stopOn = opts.stopOn
    local function result(status, extra)
        local r = { status = status, time = sim.now, ticks = sim.ticks }
        if stopOn then
            r.err = stopOn.err
            r.ret = stopOn.ret
            r.event = stopOn.crashEvent
            r.computer = stopOn
        end
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    while true do
        if opts.untilFn and opts.untilFn() then return result("until") end
        if stopOn and not stopOn.alive then return result(stopOn.status) end
        if sim.ticks >= maxTicks then
            return result("budget", { why = "event budget of " .. (opts.maxTicks or 500000) .. " exhausted at t=" .. string.format("%.1f", sim.now) .. "s" })
        end
        local e, why = popNext(deadline)
        if not e then
            if why == "budget" then
                sim.now = deadline
                return result("budget", { why = "simulated time budget of " .. (opts.maxTime or 3600) .. "s exhausted" })
            end
            return result("idle", { why = "no pending events (every program is blocked forever)" })
        end
        if e.time > sim.now then sim.now = e.time end
        sim.ticks = sim.ticks + 1
        deliver(e.c, e.args)
    end
end

-- Boot a program on a turtle or computer. args = {"prog", arg1, ...} (or a
-- function(env, computer) for scripted computers).
-- opts.background = true: just start it and return the computer.
-- Otherwise runs the scheduler until it stops (see sim.run) and returns the result.
function sim.boot(t, args, opts)
    opts = opts or {}
    local c = t.computer or t
    c.bootArgs = args
    c.crashAt = opts.crashAt
    if c.alive then c.alive = false end
    start(c)
    if opts.background then return c end
    return sim.run({ stopOn = c, untilFn = opts.untilFn, maxTime = opts.maxTime, maxTicks = opts.maxTicks })
end

-- Kill a running computer (like breaking it / chunk unload without a save).
function sim.kill(t)
    local c = t.computer or t
    c.alive = false
    c.status = "killed"
end

---------------------------------------------------------------------------
-- world snapshots (server crash with autosave lag)
---------------------------------------------------------------------------
function sim.snapshot(t)
    return {
        world = t.world:snapshot(),
        turtle = {
            pos = sim.copyPos(t.pos), facing = t.facing, fuel = t.fuel,
            inv = World.deepcopy(t.inv), selected = t.selected, equip = World.deepcopy(t.equip),
        },
        time = sim.now,
    }
end

-- Restore world + turtle (pos, facing, fuel, inventory) but NOT the fs.
function sim.rollback(t, snap)
    t.world:restore(snap.world)
    local s = snap.turtle
    t.pos = sim.copyPos(s.pos)
    t.prevPos = sim.copyPos(s.pos)
    t.facing, t.prevFacing = s.facing, s.facing
    t.fuel = s.fuel
    t.inv = World.deepcopy(s.inv)
    t.selected = s.selected
    t.equip = World.deepcopy(s.equip)
end

sim.reset()
return sim
