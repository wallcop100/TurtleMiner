-- Version: 1.0.2
-- Builds the CC global environment for one boot of one sim computer:
-- os, sleep, parallel, rednet, peripheral, gps, settings, textutils, term,
-- window, paintutils, colors, keys, shell, require, fs, turtle, pocket, io,
-- print/write/printError/read, vector, bit32.

local FS = require("fs")
local Term = require("term")
local textutils = require("textutils")
local TurtleAPI = require("turtle_api")

local Env = {}

local function cctostring(v)
    if math.type(v) == "float" and v == math.floor(v) and v > -1e15 and v < 1e15 then
        return string.format("%d", v)
    end
    return tostring(v)
end

local function copyLib(lib)
    local r = {}
    for k, v in pairs(lib) do r[k] = v end
    return r
end

local COLORS = {
    white = 0x1, orange = 0x2, magenta = 0x4, lightBlue = 0x8, yellow = 0x10, lime = 0x20,
    pink = 0x40, gray = 0x80, lightGray = 0x100, cyan = 0x200, purple = 0x400, blue = 0x800,
    brown = 0x1000, green = 0x2000, red = 0x4000, black = 0x8000,
}

local function makeColors(british)
    local c = {}
    for k, v in pairs(COLORS) do c[k] = v end
    if british then
        c.grey = c.gray; c.lightGrey = c.lightGray
        c.gray, c.lightGray = nil, nil
        c.grey, c.lightGrey = COLORS.gray, COLORS.lightGray
        c.gray, c.lightGray = COLORS.gray, COLORS.lightGray -- CC keeps both spellings in practice
    end
    function c.combine(...) local r = 0; for _, v in ipairs({ ... }) do r = r | v end; return r end
    function c.subtract(a, ...) for _, v in ipairs({ ... }) do a = a & ~v end; return a end
    function c.test(a, b) return (a & b) == b end
    function c.toBlit(col)
        local i = 0
        while col > 1 do col = col // 2; i = i + 1 end
        return ("0123456789abcdef"):sub(i + 1, i + 1)
    end
    function c.fromBlit(ch)
        local i = tonumber(ch, 16)
        return i and (1 << i) or nil
    end
    function c.packRGB(r, g, b) return math.floor(r * 255) * 65536 + math.floor(g * 255) * 256 + math.floor(b * 255) end
    function c.unpackRGB(v) return (v >> 16 & 255) / 255, (v >> 8 & 255) / 255, (v & 255) / 255 end
    c.rgb8 = function(r, g, b) if g then return c.packRGB(r, g, b) end return c.unpackRGB(r) end
    return c
end

local function makeKeys()
    local k = {
        space = 32, apostrophe = 39, comma = 44, minus = 45, period = 46, slash = 47,
        zero = 48, one = 49, two = 50, three = 51, four = 52, five = 53, six = 54, seven = 55, eight = 56, nine = 57,
        semicolon = 59, equals = 61, enter = 257, tab = 258, backspace = 259, insert = 260, delete = 261,
        right = 262, left = 263, down = 264, up = 265, pageUp = 266, pageDown = 267, home = 268, ["end"] = 269,
        capsLock = 280, f1 = 290, f2 = 291, f3 = 292, f4 = 293, f5 = 294, leftShift = 340, leftCtrl = 341,
        leftAlt = 342, rightShift = 344, rightCtrl = 345, rightAlt = 346,
    }
    for i = 0, 25 do k[string.char(97 + i)] = 65 + i end
    k["return"] = k.enter
    local names = {}
    for n, v in pairs(k) do if not names[v] then names[v] = n end end
    k.getName = function(code) return names[code] end
    return k
end

local function makeBit32()
    local M = 0xFFFFFFFF
    local b = {}
    function b.band(...) local r = M; for _, v in ipairs({ ... }) do r = r & (math.floor(v) & M) end; return r end
    function b.bor(...) local r = 0; for _, v in ipairs({ ... }) do r = r | (math.floor(v) & M) end; return r end
    function b.bxor(...) local r = 0; for _, v in ipairs({ ... }) do r = r ~ (math.floor(v) & M) end; return r end
    function b.bnot(v) return (~math.floor(v)) & M end
    function b.lshift(v, n) return (math.floor(v) << n) & M end
    function b.rshift(v, n) return (math.floor(v) & M) >> n end
    function b.arshift(v, n)
        v = math.floor(v) & M
        if v & 0x80000000 ~= 0 then return ((v >> n) | ~(M >> n)) & M end
        return v >> n
    end
    function b.btest(...) return b.band(...) ~= 0 end
    function b.extract(v, f, w) w = w or 1; return (math.floor(v) >> f) & ((1 << w) - 1) end
    return b
end

local function makeVector()
    local vector = {}
    local mt = {}
    mt.__index = mt
    local function new(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, mt) end
    function mt.add(a, b) return new(a.x + b.x, a.y + b.y, a.z + b.z) end
    function mt.sub(a, b) return new(a.x - b.x, a.y - b.y, a.z - b.z) end
    function mt.mul(a, m) return new(a.x * m, a.y * m, a.z * m) end
    function mt.div(a, m) return new(a.x / m, a.y / m, a.z / m) end
    function mt.unm(a) return new(-a.x, -a.y, -a.z) end
    function mt.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
    function mt.cross(a, b) return new(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
    function mt.length(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
    function mt.normalize(a) return a:div(a:length()) end
    function mt.round(a, t) t = t or 1; return new(math.floor(a.x / t + 0.5) * t, math.floor(a.y / t + 0.5) * t, math.floor(a.z / t + 0.5) * t) end
    function mt.tostring(a) return cctostring(a.x) .. "," .. cctostring(a.y) .. "," .. cctostring(a.z) end
    function mt.equals(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
    mt.__add, mt.__sub, mt.__mul, mt.__div, mt.__unm = mt.add, mt.sub, mt.mul, mt.div, mt.unm
    mt.__tostring, mt.__eq = mt.tostring, mt.equals
    vector.new = new
    return vector
end

-- Resolve a program name in the computer fs.
local function resolve(c, name)
    if type(name) ~= "string" then return nil end
    local p = FS.norm(name)
    if c.fs.files[p] then return p end
    if c.fs.files[p .. ".lua"] then return p .. ".lua" end
    return nil
end

function Env.build(sim, c)
    local G = {}
    G._G = G
    G._VERSION = "Lua 5.2"
    G._HOST = "ComputerCraft 1.109.0 (Minecraft 1.20.1) [sim]"
    G._CC_DEFAULT_SETTINGS = ""

    -- base library ------------------------------------------------------------
    for _, k in ipairs({ "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal",
                         "rawget", "rawlen", "rawset", "select", "setmetatable", "tonumber", "type", "xpcall" }) do
        G[k] = _G[k]
    end
    G.tostring = cctostring
    G.unpack = table.unpack
    G.string = string
    G.table = copyLib(table)
    G.math = copyLib(math)
    G.math.pow = function(a, b) return a ^ b end
    G.math.ldexp = function(m, e) return m * 2.0 ^ e end
    G.utf8 = utf8
    G.debug = debug
    G.bit32 = makeBit32()
    G.load = function(chunk, name, mode, env)
        if env == nil then env = G end
        return load(chunk, name, mode, env)
    end
    G.loadstring = function(s, name) return load(s, name, "t", G) end

    local co = copyLib(coroutine)
    co.create = function(f)
        local r = coroutine.create(f)
        sim.hookCoroutine(c, r)
        return r
    end
    co.wrap = function(f)
        local r = co.create(f)
        return function(...)
            local res = table.pack(coroutine.resume(r, ...))
            if not res[1] then error(res[2], 0) end
            return table.unpack(res, 2, res.n)
        end
    end
    G.coroutine = co

    -- fs ---------------------------------------------------------------------
    local fs = FS.api(c.fs, c)
    G.fs = fs

    G.loadfile = function(path, mode, env)
        local f = fs.open(path, "r")
        if not f then return nil, "File not found" end
        local s = f.readAll(); f.close()
        return load(s, "@/" .. FS.norm(path), mode or "t", env or G)
    end
    G.dofile = function(path)
        local fn, err = G.loadfile(path)
        if not fn then error(err, 2) end
        return fn()
    end

    -- os -----------------------------------------------------------------------
    local os_ = {}
    G.os = os_
    local function pullEventRaw(filter)
        c:guard()
        local r = table.pack(coroutine.yield(filter))
        c:guard()
        return table.unpack(r, 1, r.n)
    end
    os_.pullEventRaw = pullEventRaw
    os_.pullEvent = function(filter)
        local r = table.pack(pullEventRaw(filter))
        if r[1] == "terminate" then error("Terminated", 0) end
        return table.unpack(r, 1, r.n)
    end
    os_.queueEvent = function(name, ...)
        c:guard()
        sim.queue(c, sim.now, table.pack(name, ...))
    end
    os_.startTimer = function(t)
        c:guard()
        c.nextTimer = c.nextTimer + 1
        local id = c.nextTimer
        t = tonumber(t) or 0
        local dt = math.max(0.05, math.ceil(t * 20 - 1e-9) / 20)
        sim.queue(c, sim.now + dt, { "timer", id, n = 2 })
        return id
    end
    os_.cancelTimer = function(id) c.cancelled[id] = true end
    os_.setAlarm = function(time)
        c.nextTimer = c.nextTimer + 1
        local id = c.nextTimer
        local now = os_.time()
        local dh = (time - now) % 24
        sim.queue(c, sim.now + dh * 50, { "alarm", id, n = 2 })
        return id
    end
    os_.cancelAlarm = os_.cancelTimer
    os_.getComputerID = function() return c.id end
    os_.computerID = os_.getComputerID
    os_.getComputerLabel = function() return c.label end
    os_.computerLabel = os_.getComputerLabel
    os_.setComputerLabel = function(l) c.label = l end
    os_.clock = function() return sim.now - (c.bootTime or 0) end
    os_.time = function(arg)
        if type(arg) == "table" then return os.time(arg) end
        if arg == "utc" or arg == "local" then
            return ((sim.BASE_EPOCH / 1000 + sim.now) % 86400) / 3600
        end
        return (6 + sim.now / 50) % 24
    end
    os_.day = function(arg)
        if arg == "utc" or arg == "local" then return math.floor((sim.BASE_EPOCH / 1000 + sim.now) / 86400) end
        return math.floor((6 + sim.now / 50) / 24)
    end
    os_.epoch = function(kind)
        kind = kind or "ingame"
        if kind == "ingame" then return math.floor(sim.now * 72000) end
        return math.floor(sim.BASE_EPOCH + sim.now * 1000)
    end
    os_.date = function(fmt, t) return os.date(fmt, t or math.floor(sim.BASE_EPOCH / 1000 + sim.now)) end
    os_.version = function() return "CraftOS 1.9" end
    os_.reboot = function()
        c.rebootReq = true
        c:halt({ kind = "reboot" }, "reboot")
    end
    os_.shutdown = function()
        c.shutdownReq = true
        c:halt({ kind = "shutdown" }, "shutdown")
    end
    os_.sleep = nil

    local function sleep(t)
        local id = os_.startTimer(t or 0)
        repeat
            local _, p = os_.pullEvent("timer")
        until p == id
    end
    G.sleep = sleep
    os_.sleep = sleep

    -- term -----------------------------------------------------------------------
    local native = c.term
    local current = native
    local term = {}
    for k, f in pairs(native) do
        if type(f) == "function" and k:sub(1, 1) ~= "_" then
            term[k] = function(...) return current[k](...) end
        end
    end
    term.native = function() return native end
    term.current = function() return current end
    term.redirect = function(target)
        if type(target) ~= "table" then error("bad argument #1 (table expected)", 2) end
        local old = current
        current = target
        return old
    end
    G.term = term

    local function out(s)
        c.output[#c.output + 1] = s
        if sim.verbose then io.stderr:write("[" .. c.id .. "] " .. s) end
    end

    local function write(s)
        s = cctostring(s)
        out(s)
        local w, h = current.getSize()
        local lines = 0
        local function newline()
            local _, y = current.getCursorPos()
            if y + 1 > h then
                current.scroll(1)
                current.setCursorPos(1, h)
            else
                current.setCursorPos(1, y + 1)
            end
            lines = lines + 1
        end
        local i = 1
        while i <= #s do
            local ch = s:sub(i, i)
            if ch == "\n" then
                newline()
                i = i + 1
            else
                local j = s:find("\n", i, true) or (#s + 1)
                local chunk = s:sub(i, j - 1)
                while #chunk > 0 do
                    local x, y = current.getCursorPos()
                    if y < 1 or y > h then
                        newline(); x, y = current.getCursorPos()
                    end
                    local room = w - x + 1
                    if room <= 0 then newline(); room = w; x = 1 end
                    local part = chunk:sub(1, room)
                    current.write(part)
                    chunk = chunk:sub(room + 1)
                    if #chunk > 0 then newline() end
                end
                i = j
            end
        end
        return lines
    end
    G.write = write
    G.print = function(...)
        local parts = {}
        local n = select("#", ...)
        for i = 1, n do parts[i] = cctostring((select(i, ...))) end
        return write(table.concat(parts, " ") .. "\n")
    end
    G.printError = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = cctostring((select(i, ...))) end
        c.errors = c.errors or {}
        c.errors[#c.errors + 1] = table.concat(parts, " ")
        return G.print(...)
    end
    G.read = function()
        -- A miner must never prompt. Record the call and block like a real read() would.
        c.readCalls[#c.readCalls + 1] = { time = sim.now, trace = debug.traceback("read() called", 2) }
        while true do os_.pullEvent("sim_never") end
    end

    -- io (subset) ---------------------------------------------------------------
    G.io = {
        write = function(...) for _, v in ipairs({ ... }) do write(v) end end,
        read = function() return G.read() end,
        open = function(path, mode)
            mode = mode or "r"
            local h, err = fs.open(path, mode)
            if not h then return nil, err end
            local f = {}
            function f:read(fmt)
                fmt = (fmt or "l"):gsub("^%*", "")
                if fmt == "a" then return h.readAll() or "" end
                if fmt == "L" then return h.readLine(true) end
                if fmt == "n" then local l = h.readLine(); return l and tonumber(l) end
                return h.readLine()
            end
            function f:lines() return function() return h.readLine() end end
            function f:write(...) for _, v in ipairs({ ... }) do h.write(v) end; return self end
            function f:close() h.close() end
            function f:flush() if h.flush then h.flush() end end
            return f
        end,
        lines = function(path)
            local h = fs.open(path, "r")
            if not h then error("No such file", 2) end
            return function()
                local l = h.readLine()
                if not l then h.close() end
                return l
            end
        end,
    }

    -- textutils -------------------------------------------------------------
    local tu = copyLib(textutils)
    tu.slowPrint = function(s) G.print(s) end
    tu.slowWrite = function(s) write(s) end
    tu.pagedPrint = function(s) G.print(s) end
    tu.tabulate = function(...)
        for _, row in ipairs({ ... }) do
            if type(row) == "table" then
                local parts = {}
                for _, v in ipairs(row) do parts[#parts + 1] = cctostring(v) end
                G.print(table.concat(parts, " "))
            end
        end
    end
    tu.pagedTabulate = tu.tabulate
    G.textutils = tu

    G.colors = makeColors(false)
    G.colours = makeColors(true)
    G.keys = makeKeys()
    G.vector = makeVector()

    -- window / paintutils ----------------------------------------------------
    G.window = {
        create = function(parent, x, y, w, h, visible)
            return Term.window(parent, x, y, w, h, visible)
        end,
    }
    G.paintutils = {
        drawPixel = function(x, y, col)
            if col then current.setBackgroundColor(col) end
            current.setCursorPos(x, y); current.write(" ")
        end,
        drawLine = function(x1, y1, x2, y2, col)
            if col then current.setBackgroundColor(col) end
            if y1 == y2 then
                current.setCursorPos(math.min(x1, x2), y1)
                current.write(string.rep(" ", math.abs(x2 - x1) + 1))
            else
                for y = math.min(y1, y2), math.max(y1, y2) do
                    local x = x1 + math.floor((x2 - x1) * (y - y1) / (y2 - y1) + 0.5)
                    current.setCursorPos(x, y); current.write(" ")
                end
            end
        end,
        drawFilledBox = function(x1, y1, x2, y2, col)
            if col then current.setBackgroundColor(col) end
            for y = math.min(y1, y2), math.max(y1, y2) do
                current.setCursorPos(math.min(x1, x2), y)
                current.write(string.rep(" ", math.abs(x2 - x1) + 1))
            end
        end,
    }
    G.paintutils.drawBox = function(x1, y1, x2, y2, col)
        G.paintutils.drawLine(x1, y1, x2, y1, col)
        G.paintutils.drawLine(x1, y2, x2, y2, col)
        G.paintutils.drawLine(x1, y1, x1, y2, col)
        G.paintutils.drawLine(x2, y1, x2, y2, col)
    end

    -- redstone stub
    local rs = {
        getSides = function() return { "top", "bottom", "left", "right", "front", "back" } end,
        getInput = function() return false end, getOutput = function() return false end,
        setOutput = function() end, getAnalogInput = function() return 0 end,
        getAnalogOutput = function() return 0 end, setAnalogOutput = function() end,
    }
    G.redstone, G.rs = rs, rs

    -- peripheral -------------------------------------------------------------
    local SIDES = { "top", "bottom", "left", "right", "front", "back" }
    local wrappedName = setmetatable({}, { __mode = "k" })
    local peripheral = {}
    local function wrapP(side, p)
        local obj = {}
        for k, f in pairs(p.methods) do obj[k] = f end
        wrappedName[obj] = side
        setmetatable(obj, { __name = "peripheral", types = p.types })
        return obj
    end
    local function at(side)
        if type(side) == "table" then side = wrappedName[side] end
        if type(side) ~= "string" then return nil end
        return sim.peripheralAt(c, side), side
    end
    function peripheral.getNames()
        local r = {}
        for _, s in ipairs(SIDES) do if sim.peripheralAt(c, s) then r[#r + 1] = s end end
        for s in pairs(c.peripherals) do
            local known = false
            for _, x in ipairs(SIDES) do if x == s then known = true end end
            if not known then r[#r + 1] = s end
        end
        return r
    end
    function peripheral.isPresent(side) return (at(side)) ~= nil end
    function peripheral.getType(side)
        local p = at(side)
        if not p then return nil end
        return table.unpack(p.types)
    end
    function peripheral.hasType(side, tp)
        local p = at(side)
        if not p then return nil end
        for _, x in ipairs(p.types) do if x == tp then return true end end
        return false
    end
    function peripheral.getMethods(side)
        local p = at(side)
        if not p then return nil end
        local r = {}
        for k in pairs(p.methods) do r[#r + 1] = k end
        table.sort(r)
        return r
    end
    function peripheral.getName(obj)
        local n = wrappedName[obj]
        if not n then error("bad argument #1 (table is not a peripheral)", 2) end
        return n
    end
    function peripheral.wrap(side)
        local p = at(side)
        if not p then return nil end
        return wrapP(side, p)
    end
    function peripheral.call(side, method, ...)
        local p = at(side)
        if not p then error("No peripheral attached", 2) end
        local f = p.methods[method]
        if not f then error("No such method " .. tostring(method), 2) end
        return f(...)
    end
    function peripheral.find(tp, filter)
        local r = {}
        for _, s in ipairs(peripheral.getNames()) do
            if peripheral.hasType(s, tp) then
                local obj = peripheral.wrap(s)
                if not filter or filter(s, obj) then r[#r + 1] = obj end
            end
        end
        return table.unpack(r)
    end
    G.peripheral = peripheral

    -- rednet ---------------------------------------------------------------------
    local rednet = { CHANNEL_BROADCAST = 65535, CHANNEL_REPEAT = 65533, MAX_ID_CHANNELS = 65500 }
    local hosted = {}
    function rednet.open(side)
        local p = sim.peripheralAt(c, side)
        if not p or p.types[1] ~= "modem" then error("No such modem: " .. tostring(side), 2) end
        c.rednetOpen[side] = true
    end
    function rednet.close(side)
        if side then c.rednetOpen[side] = nil else c.rednetOpen = {} end
    end
    function rednet.isOpen(side)
        if side then return c.rednetOpen[side] == true end
        for s, v in pairs(c.rednetOpen) do
            if v and sim.peripheralAt(c, s) then return true end
        end
        return false
    end
    function rednet.send(id, msg, protocol)
        c:guard()
        if not rednet.isOpen() then return false end
        sim.net.deliver(c.id, id, msg, protocol)
        return true
    end
    function rednet.broadcast(msg, protocol)
        c:guard()
        if not rednet.isOpen() then return end
        sim.net.deliver(c.id, nil, msg, protocol)
    end
    function rednet.receive(protocol, timeout)
        if type(protocol) == "number" and timeout == nil then protocol, timeout = nil, protocol end
        local timer = timeout and os_.startTimer(timeout)
        while true do
            local e = table.pack(os_.pullEvent())
            if e[1] == "rednet_message" and (protocol == nil or e[4] == protocol) then
                return e[2], e[3], e[4]
            elseif e[1] == "timer" and e[2] == timer then
                return nil
            end
        end
    end
    function rednet.host(protocol, name) hosted[protocol] = name end
    function rednet.unhost(protocol) hosted[protocol] = nil end
    function rednet.lookup(protocol, name)
        local r = {}
        for _, o in ipairs(sim.computers) do
            if o ~= c and o.alive and o.env and o.env._rednetHosted then
                local n = o.env._rednetHosted[protocol]
                if n and (name == nil or n == name) then r[#r + 1] = o.id end
            end
        end
        if name then return r[1] end
        return table.unpack(r)
    end
    G._rednetHosted = hosted
    function rednet.run()
        while true do os_.pullEventRaw() end
    end
    G.rednet = rednet

    -- gps ----------------------------------------------------------------------
    G.gps = {
        CHANNEL_GPS = 65534,
        locate = function(timeout)
            local hasModem = false
            for _, s in ipairs(SIDES) do
                local p = sim.peripheralAt(c, s)
                if p and p.types[1] == "modem" and p.methods.isWireless() then hasModem = true end
            end
            if not hasModem then return nil end
            c.gpsLocates = (c.gpsLocates or 0) + 1
            -- t.gpsMinY: GPS hosts out of modem range below this Y (64-block wireless range)
            local t = c.turtle
            if c.gps and t and not (t.gpsMinY and t.pos.y < t.gpsMinY) then
                sleep(0.1)
                local p = c.turtle.pos
                return p.x, p.y, p.z
            end
            sleep(timeout or 2)
            return nil
        end,
    }

    -- settings ------------------------------------------------------------------
    local defs = {}
    local settings = {}
    function settings.define(name, opts) defs[name] = opts or {} end
    function settings.undefine(name) defs[name] = nil end
    function settings.get(name, default)
        local v = c.settings[name]
        if v ~= nil then return v end
        if default ~= nil then return default end
        return defs[name] and defs[name].default
    end
    function settings.set(name, value)
        if type(value) == "function" or type(value) == "thread" then error("bad argument #2", 2) end
        c.settings[name] = value
    end
    function settings.unset(name) c.settings[name] = nil end
    function settings.clear() c.settings = {} end
    function settings.getNames()
        local r = {}
        for k in pairs(c.settings) do r[#r + 1] = k end
        for k in pairs(defs) do if c.settings[k] == nil then r[#r + 1] = k end end
        table.sort(r)
        return r
    end
    function settings.getDetails(name)
        local d = defs[name] or {}
        return { description = d.description, default = d.default, type = d.type, value = c.settings[name] }
    end
    function settings.load(path)
        local h = fs.open(path or ".settings", "r")
        if not h then return false end
        local s = h.readAll(); h.close()
        local t = textutils.unserialize(s)
        if type(t) ~= "table" then return false end
        for k, v in pairs(t) do c.settings[k] = v end
        return true
    end
    function settings.save(path)
        local h = fs.open(path or ".settings", "w")
        if not h then return false end
        h.write(textutils.serialize(c.settings))
        h.close()
        return true
    end
    G.settings = settings

    -- parallel (same algorithm as CC's bios) -------------------------------------
    local function createAll(...)
        local fns = table.pack(...)
        local cos = {}
        for i = 1, fns.n do
            if type(fns[i]) ~= "function" then error("bad argument #" .. i .. " (function expected, got " .. type(fns[i]) .. ")", 3) end
            cos[i] = co.create(fns[i])
        end
        return cos, fns.n
    end
    local function runUntilLimit(routines, count, limit)
        if count < 1 then return 0 end
        local living = count
        local filters = {}
        local eventData = { n = 0 }
        while true do
            for n = 1, count do
                local r = routines[n]
                if r then
                    if filters[r] == nil or filters[r] == eventData[1] or eventData[1] == "terminate" then
                        local ok, param = coroutine.resume(r, table.unpack(eventData, 1, eventData.n))
                        if not ok then error(param, 0) end
                        filters[r] = param
                        if coroutine.status(r) == "dead" then
                            routines[n] = nil
                            living = living - 1
                            if living <= limit then return n end
                        end
                    end
                end
            end
            eventData = table.pack(pullEventRaw())
        end
    end
    G.parallel = {
        waitForAny = function(...)
            local r, n = createAll(...)
            return runUntilLimit(r, n, n - 1)
        end,
        waitForAll = function(...)
            local r, n = createAll(...)
            return runUntilLimit(r, n, 0)
        end,
    }

    -- turtle / pocket ---------------------------------------------------------------
    if c.turtle then
        G.turtle = TurtleAPI.build(sim, c, c.turtle)
        G.turtle.native = G.turtle
    end
    if c.pocket then
        G.pocket = {
            equipBack = function() return false, "Cannot equip" end,
            unequipBack = function() return false, "Nothing to unequip" end,
        }
    end

    -- shell --------------------------------------------------------------------
    local shell = {}
    local running = {}
    function shell.resolve(p) return FS.norm(p) end
    function shell.resolveProgram(p) return resolve(c, p) end
    function shell.dir() return "" end
    function shell.setDir() end
    function shell.path() return ".:/rom/programs" end
    function shell.setPath() end
    function shell.aliases() return {} end
    function shell.setAlias() end
    function shell.clearAlias() end
    function shell.programs() return {} end
    function shell.getRunningProgram() return running[#running] end
    function shell.exit() end
    function shell.openTab() return nil end
    function shell.complete() return {} end
    function shell.run(...)
        local words = {}
        for _, a in ipairs({ ... }) do
            for wd in tostring(a):gmatch("%S+") do words[#words + 1] = wd end
        end
        if #words == 0 then return false end
        local fn, err = Env.program(sim, c, G, words[1], table.pack(table.unpack(words, 2)))
        if not fn then
            G.printError(err)
            return false
        end
        local ok, e = pcall(fn)
        if not ok then
            G.printError(tostring(e))
            return false
        end
        return true
    end
    shell.execute = shell.run
    G.shell = shell
    G._shellRunning = running

    return G
end

-- Load program `name` for computer c; returns a function that runs it with args.
function Env.program(sim, c, G, name, args)
    local path = resolve(c, name)
    if not path then return nil, "No such program: " .. tostring(name) end
    local penv = setmetatable({}, { __index = G })
    penv.shell = G.shell
    penv.arg = { [0] = path }
    for i = 1, args.n or #args do penv.arg[i] = args[i] end

    local loaded = {
        _G = G, string = G.string, table = G.table, math = G.math, coroutine = G.coroutine,
        os = G.os, io = G.io, utf8 = G.utf8, bit32 = G.bit32,
    }
    -- Like CC's cc.require: relative patterns resolve against the running program's directory,
    -- absolute ones ("/...") against the root; /rom module dirs are on the default path.
    local progDir = path:match("^(.*)/[^/]*$") or ""
    local package = { loaded = loaded, preload = {}, config = "/\n;\n?\n!\n-",
        path = "?;?.lua;?/init.lua;/rom/modules/main/?;/rom/modules/main/?.lua;/rom/modules/main/?/init.lua"
            .. (c.turtle and ";/rom/modules/turtle/?;/rom/modules/turtle/?.lua;/rom/modules/turtle/?/init.lua" or "") }
    package.searchers = {}
    local loading = {}
    local function require(modname)
        if loaded[modname] ~= nil then return loaded[modname] end
        if package.preload[modname] then
            local r = package.preload[modname](modname)
            if r == nil then r = true end
            loaded[modname] = r
            return r
        end
        local base = modname:gsub("%.", "/")
        local tried = {}
        for pat in package.path:gmatch("[^;]+") do
            local sp = pat:gsub("%?", base)
            if sp:sub(1, 1) ~= "/" and progDir ~= "" then sp = progDir .. "/" .. sp end
            local p = FS.norm(sp)
            tried[#tried + 1] = "  /" .. p
            local src = c.fs.files[p]
            if src then
                if loading[modname] then error("loop or previous error loading module '" .. modname .. "'", 2) end
                loading[modname] = true
                local fn, err = load(src, "@/" .. p, "t", penv)
                if not fn then loading[modname] = nil; error(err, 0) end
                local r = fn(modname, p)
                loading[modname] = nil
                if r == nil then r = true end
                if loaded[modname] == nil then loaded[modname] = r end
                return loaded[modname]
            end
        end
        error("module '" .. modname .. "' not found:\n  no field package.preload['" .. modname .. "']\n" .. table.concat(tried, "\n"), 2)
    end
    penv.require = require
    penv.package = package

    local fn, err = load(c.fs.files[path], "@/" .. path, "t", penv)
    if not fn then return nil, err end
    local running = G._shellRunning
    return function()
        running[#running + 1] = path
        local r = table.pack(fn(table.unpack(args, 1, args.n or #args)))
        running[#running] = nil
        return table.unpack(r, 1, r.n)
    end
end

return Env
