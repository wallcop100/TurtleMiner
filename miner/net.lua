-- Version: 1.0.0
-- TurtleMiner network layer (TMINER protocol v1, see docs/PROTOCOL.md).
-- One rednet wrapper for the whole turtle. Never moves the turtle, never relays.
-- Works offline: with no modem every send is a silent no-op.

local net = {}

local PROTO        = "TMINER"
local MAX_HOPS     = 4
local DEDUPE_SIZE  = 256
local INBOX_MAX    = 64
local EV_STATUS    = "tminer_status"
local EV_REPLY     = "tminer_reply"

local KNOWN_CMDS = {
    RETURN_HOME = true, PAUSE = true, RESUME = true, SET = true,
    REQUEST_STATUS = true, RESET_JOB = true, RESET_HOME = true,
    UPDATE = true, REBOOT = true,
}

local cfg         = { STATUS_INTERVAL = 10 }
local myId        = os.getComputerID()
local bootId      = os.epoch("utc")
-- Random start: two programs booting in the same millisecond must not share keys.
local seq         = math.random(1, 1000000)
local inbox       = {}
local waiting     = {}     -- replyKind -> number of pending requests
local replies     = {}     -- replyKind -> msg
local statusWanted = false
local validator   = nil    -- optional fn(cmd, params) -> ok, err (used for the ack)

-- Fixed-size set: remembers the last n keys.
local function newRing(n) return { n = n, set = {}, list = {}, i = 0 } end
local function ringHas(r, k) return r.set[k] ~= nil end
local function ringAdd(r, k)
    if r.set[k] then return end
    r.i = (r.i % r.n) + 1
    local old = r.list[r.i]
    if old ~= nil then r.set[old] = nil end
    r.list[r.i] = k
    r.set[k] = true
end

local seen    = newRing(DEDUPE_SIZE)  -- envelope dedupe keys
local cmdSeen = newRing(DEDUPE_SIZE)  -- cmd ids already queued (server retries)

-- Modems ---------------------------------------------------------------------

local function openModems()
    if not (peripheral and rednet) then return false end
    local okN, names = pcall(peripheral.getNames)
    if not okN or type(names) ~= "table" then return false end
    local wireless, wired = {}, {}
    for _, n in ipairs(names) do
        local okT, t = pcall(peripheral.getType, n)
        if okT and t == "modem" then
            local okW, w = pcall(peripheral.call, n, "isWireless")
            if okW and w then wireless[#wireless + 1] = n else wired[#wired + 1] = n end
        end
    end
    local any = false
    local function open(n)
        local ok = pcall(rednet.open, n)
        if ok then
            local okO, isOpen = pcall(rednet.isOpen, n)
            if okO and isOpen then any = true end
        end
    end
    for _, n in ipairs(wireless) do open(n) end
    for _, n in ipairs(wired) do open(n) end
    return any
end

function net.online()
    if not rednet then return false end
    local ok, open = pcall(rednet.isOpen)
    return ok and open == true
end

function net.init(c)
    if type(c) == "table" then cfg = c end
    openModems()
    if net.online() then return true end
    return false, "no modem"
end

function net.setValidator(fn) validator = fn end

-- Sending --------------------------------------------------------------------

function net.send(kind, to, body)
    seq = seq + 1
    local msg = {}
    if type(body) == "table" then
        for k, v in pairs(body) do msg[k] = v end
    end
    msg.v, msg.kind, msg.from = 1, kind, myId
    msg.to = to or "server"
    msg.boot, msg.seq, msg.ts, msg.hops = bootId, seq, os.epoch("utc"), 0
    if not net.online() then return false end
    -- Broadcast so every server (and relay) hears it; `to` says who it's for.
    local ok = pcall(rednet.broadcast, msg, PROTO)
    return ok
end

function net.event(level, text)
    return net.send("event", "server", {
        level = level or "info",
        text = string.sub(tostring(text), 1, 200),
    })
end

local function ack(to, id, ok, err)
    net.send("ack", to or "server", { id = id, ok = ok and true or false, err = err })
end

-- Receiving ------------------------------------------------------------------

local function handleCmd(msg)
    local id, c = msg.id, msg.cmd
    local params = type(msg.params) == "table" and msg.params or {}
    if type(c) ~= "string" then
        ack(msg.from, id, false, "bad cmd")
        return
    end
    if id ~= nil and ringHas(cmdSeen, tostring(id)) then
        ack(msg.from, id, true)          -- retry of a command we already have
        return
    end
    local ok, err = true, nil
    if not KNOWN_CMDS[c] then
        ok, err = false, "unknown cmd " .. c
    elseif validator then
        local vok, a, b = pcall(validator, c, params)
        if not vok then ok, err = false, tostring(a)
        elseif a == false then ok, err = false, b end
    end
    if ok and #inbox >= INBOX_MAX then ok, err = false, "inbox full" end
    ack(msg.from, id, ok, err)
    if not ok then return end
    if id ~= nil then ringAdd(cmdSeen, tostring(id)) end
    inbox[#inbox + 1] = { id = id, cmd = c, params = params }
    if c == "REQUEST_STATUS" then net.statusNow() end
end

-- Idempotent: both net.run and net.request may call it for the same event;
-- the dedupe ring makes sure each message is processed once.
local function handle(msg)
    if type(msg) ~= "table" or msg.v ~= 1 or type(msg.kind) ~= "string" then return end
    if msg.from == myId then return end
    if type(msg.hops) == "number" and msg.hops > MAX_HOPS then return end
    local key = tostring(msg.from) .. ":" .. tostring(msg.boot) .. ":" .. tostring(msg.seq)
    if ringHas(seen, key) then return end
    ringAdd(seen, key)
    local to = msg.to
    if to ~= "all" and tonumber(to) ~= myId then return end
    if msg.kind == "cmd" then
        handleCmd(msg)
    elseif waiting[msg.kind] and waiting[msg.kind] > 0 then
        replies[msg.kind] = msg
        os.queueEvent(EV_REPLY, msg.kind)
    end
end

local function onEvent(ev)
    if ev[1] == "rednet_message" and ev[4] == PROTO then handle(ev[3]) end
end

function net.poll()
    if #inbox == 0 then return nil end
    return table.remove(inbox, 1)
end

function net.statusNow()
    statusWanted = true
    os.queueEvent(EV_STATUS)
end

-- Safe from the worker coroutine while net.run runs in parallel: parallel
-- hands every event to both coroutines, and handle() is deduped.
function net.request(kind, body, replyKind, timeout)
    if not net.online() then return nil end
    replyKind = replyKind or kind
    waiting[replyKind] = (waiting[replyKind] or 0) + 1
    replies[replyKind] = nil
    net.send(kind, "server", body)
    local timer = os.startTimer(timeout or 3)
    local result
    while true do
        if replies[replyKind] then result = replies[replyKind]; break end
        local ev = { os.pullEvent() }
        if ev[1] == "timer" and ev[2] == timer then break end
        onEvent(ev)
    end
    if result then pcall(os.cancelTimer, timer) end
    waiting[replyKind] = waiting[replyKind] - 1
    if waiting[replyKind] <= 0 then waiting[replyKind] = nil; replies[replyKind] = nil end
    return result
end

local function interval()
    local s = tonumber(cfg.STATUS_INTERVAL) or 10
    if s < 1 then s = 1 end
    return s
end

local function sendStatus(getStatus)
    local ok, st = pcall(getStatus)
    if ok and type(st) == "table" then net.send("status", "server", st) end
end

-- Coroutine body. Never returns (except by "Terminated").
function net.run(getStatus)
    local timer = os.startTimer(interval())
    sendStatus(getStatus)
    while true do
        local ev = { os.pullEvent() }
        local e = ev[1]
        if e == "timer" and ev[2] == timer then
            statusWanted = true
            timer = os.startTimer(interval())
        elseif e == "peripheral" or e == "peripheral_detach" then
            openModems()
        else
            onEvent(ev)
        end
        if statusWanted then
            statusWanted = false
            sendStatus(getStatus)
        end
    end
end

return net
