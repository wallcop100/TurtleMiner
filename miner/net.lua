-- Version: 1.4.0
-- TurtleMiner network layer (TMINER protocol v1, see docs/PROTOCOL.md and docs/COMMS.md).
-- One rednet wrapper for the whole turtle. Never moves the turtle.
-- Works offline: with no modem every send is a silent no-op.
-- Everything about the network is detected at runtime, nothing is configured:
--   own modem kind (none/basic/ender/wired), distance to the server in hops (learned from what
--   it hears), whether it is in contact (heard a server/relay in the last 30 s).
-- Out of contact: status sends are skipped, events are buffered (coalesced, max 50) and sent as
-- one `catchup` message when contact returns. Relays TMINER traffic for other turtles when
-- that helps (ender modem: always; basic modem: only when it moves the message closer).
-- Mining network (docs/PROTOCOL.md "Signing"): every message is signed with the key in
-- .tm_network (tmcrypto.lua); unsigned, foreign, tampered, replayed or stale messages are
-- dropped (never relayed) and counted in net.stats.bad. No network file: nothing is sent or
-- accepted. Duplicates are checked before the signature, so repeats cost nothing.
-- Mesh updates (tmmesh.lua): status/hello carry the version summary `vs` (and `us`, what the
-- update is doing); summaries heard from others trigger fetches; list/file requests addressed
-- to this turtle are served. net.mesh() returns the engine (miner applies at home).

local net = {}

local PROTO        = "TMINER"
local MAX_HOPS     = 4        -- relay count limit (envelope `hops`)
local DEDUPE_SIZE  = 256
local INBOX_MAX    = 64
local EV_STATUS    = "tminer_status"
local EV_REPLY     = "tminer_reply"
local CONTACT_MS   = 30000    -- heard a server/relay within this = in contact
local HOP_LIMIT    = 8        -- hop distances at or above this mean "no route"
local CATCHUP_MAX  = 50
local FAR          = 400      -- blocks: beyond any basic modem's range (384 at build height)
local HOUSEKEEP    = 2        -- s between contact checks in net.run
-- Kinds only servers send: an old server without the `hop` field still counts as hop 0.
local SERVER_KINDS = { fleet = true, cmd = true, home = true, update_manifest = true, file = true }

local KNOWN_CMDS = {
    RETURN_HOME = true, PAUSE = true, RESUME = true, SET = true,
    REQUEST_STATUS = true, RESET_JOB = true, RESET_HOME = true,
    UPDATE = true, REBOOT = true, ARMY_JOIN = true, ARMY_LEAVE = true,
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
local statusDeferred = false   -- a status was skipped out of contact: send the newest on contact
local kindHooks   = {}     -- kind -> fn(msg): unsolicited replies (army_cfg)
local validator   = nil    -- optional fn(cmd, params) -> ok, err (used for the ack)

local function now() return os.epoch("utc") end

-- Signing -----------------------------------------------------------------------
local function loadMod(name)
    if require then
        local ok, m = pcall(require, name)
        if ok and type(m) == "table" then return m end
    end
    for _, p in ipairs({ name .. ".lua", "/" .. name .. ".lua" }) do
        if fs and fs.exists(p) then
            local fn = loadfile(p, nil, _ENV)
            local ok, m = pcall(fn or error)
            if ok and type(m) == "table" then return m end
        end
    end
    return nil
end
local crypto = loadMod("tmcrypto")
local Mesh = loadMod("tmmesh")
local GpsMobile = loadMod("gpsmobile")
local signer = nil        -- nil: no network (send nothing, accept nothing)
local netName = nil
local mesh = nil          -- tmmesh engine (needs the network)
local netKey = nil

local function loadNetwork()
    signer, netName, netKey = nil, nil, nil
    if not crypto then return end
    local n = crypto.loadNetwork()
    if n then signer, netName, netKey = crypto.signer(n), n.name, n.key end
end
loadNetwork()

-- Fixed-size set: remembers the last n keys.
local function newRing(n) return { n = n, set = {}, list = {}, i = 0 } end
local function ringHas(r, k) return r.set[k] ~= nil end
local function ringAdd(r, k, v)
    if r.set[k] then return end
    r.i = (r.i % r.n) + 1
    local old = r.list[r.i]
    if old ~= nil then r.set[old] = nil end
    r.list[r.i] = k
    r.set[k] = v or true
end

local seen    = newRing(DEDUPE_SIZE)  -- envelope dedupe keys -> the verified `sig`
local badSeen = newRing(64)           -- key|sig of copies that failed the check (no 2nd HMAC)
local cmdSeen = newRing(DEDUPE_SIZE)  -- cmd ids already queued (server retries)

-- Modems ---------------------------------------------------------------------
-- kind: "ender" if any wireless modem is an ender (advanced) modem, else "basic" if any
-- wireless, else "wired" if any wired, else "none". Ender detection: the equipped upgrade's
-- item name or the peripheral name contains "advanced"; or we heard a basic-modem sender from
-- beyond any basic range (only an ender receiver can). Settings tminer.MODEM / tminer.RELAY
-- only override.

local modem = { kind = "none", ender = false, basic = false, wired = false, inferred = false }
local relayMode = "auto"     -- "auto" | "on" | "off"

local function setting(key)
    if not (settings and settings.get) then return nil end
    local ok, v = pcall(settings.get, "tminer." .. key)
    if ok then return v end
    return nil
end

local function readOverrides()
    local r = setting("RELAY")
    if r == nil then r = cfg.RELAY end
    if r == true or r == "on" or r == "true" then relayMode = "on"
    elseif r == false or r == "off" or r == "false" then relayMode = "off"
    else relayMode = "auto" end
end

local function equippedName(side)
    if not turtle then return nil end
    local fn
    if side == "left" then fn = turtle.getEquippedLeft elseif side == "right" then fn = turtle.getEquippedRight end
    if type(fn) ~= "function" then return nil end
    local ok, d = pcall(fn)
    if ok and type(d) == "table" and type(d.name) == "string" then return d.name end
    return nil
end

local function updateKind()
    local o = setting("MODEM") or cfg.MODEM
    if o == "ender" or o == "basic" or o == "wired" or o == "none" then modem.kind = o; return end
    if modem.ender or (modem.inferred and modem.basic) then modem.kind = "ender"
    elseif modem.basic then modem.kind = "basic"
    elseif modem.wired then modem.kind = "wired"
    else modem.kind = "none" end
end

local function openModems()
    modem.ender, modem.basic, modem.wired = false, false, false
    if not (peripheral and rednet) then updateKind(); return false end
    local okN, names = pcall(peripheral.getNames)
    if not okN or type(names) ~= "table" then updateKind(); return false end
    local wireless, wired = {}, {}
    for _, n in ipairs(names) do
        local okT, t = pcall(peripheral.getType, n)
        if okT and t == "modem" then
            local okW, w = pcall(peripheral.call, n, "isWireless")
            if okW and w then
                wireless[#wireless + 1] = n
                local item = equippedName(n)
                if (item and string.find(item, "advanced", 1, true)) or string.find(n, "advanced", 1, true) then
                    modem.ender = true
                else
                    modem.basic = true
                end
            else
                wired[#wired + 1] = n
                modem.wired = true
            end
        end
    end
    updateKind()
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
    if not rednet or not signer then return false end
    local ok, open = pcall(rednet.isOpen)
    return ok and open == true
end

function net.modemKind() return modem.kind end
function net.network() return netName end      -- nil: not in a mining network

-- Hops (distance to the server) ------------------------------------------------
-- neigh[id] = {hop, t}: what each directly heard transmitter says its distance is. My hop is
-- 1 + the smallest fresh one (split horizon: adverts derived from me are ignored).
-- nodeHop[id] = {hop, t}: an origin's own distance (`ohop`), used to relay towards it.

local neigh, nodeHop = {}, {}
local everHeard, graceUntil = false, now() + CONTACT_MS
local lastHeard = 0

function net.hop()
    local t, best, via = now(), nil, nil
    for id, e in pairs(neigh) do
        if t - e.t > CONTACT_MS then
            neigh[id] = nil
        elseif not best or e.hop < best then
            best, via = e.hop, id
        end
    end
    if best and best + 1 < HOP_LIMIT then return best + 1, via end
    return nil
end

-- In contact: heard a server or relay (anything carrying a hop distance) in the last 30 s.
-- Right after boot, before anything was heard, the first 30 s count as contact.
function net.inContact()
    if not net.online() then return false end
    if net.hop() then return true end
    return (not everHeard) and now() < graceUntil
end

-- Catch-up buffer ------------------------------------------------------------------
-- buf: events not (known to be) delivered; sentLog: events sent but not yet confirmed by
-- hearing a server/relay afterwards (re-buffered if contact turns out to be lost).

local buf, sentLog, dropped = {}, {}, 0
local evSeq = 0

local function coKey(level, text)
    local k = string.gsub(text, "%d+", "#")
    return tostring(level) .. "|" .. k
end

local function bufferAdd(e)
    local key = coKey(e.level, e.text)
    for i = #buf, 1, -1 do
        local b = buf[i]
        if b.key == key then
            b.n = b.n + (e.n or 1)
            if (e.last or e.ts) > (b.last or b.ts) then b.last = e.last or e.ts; b.text = e.text end
            return
        end
    end
    buf[#buf + 1] = { key = key, eid = e.eid, ts = e.ts, last = e.last or e.ts, n = e.n or 1, level = e.level, text = e.text }
    while #buf > CATCHUP_MAX do
        local idx = 1
        for i, b in ipairs(buf) do if b.level == "info" then idx = i; break end end
        table.remove(buf, idx)
        dropped = dropped + 1
    end
end

local function confirmSent(upTo)
    local i = 1
    while i <= #sentLog do
        if sentLog[i].sentAt <= upTo then table.remove(sentLog, i) else i = i + 1 end
    end
end

local function rebufferSent()
    local list = sentLog
    sentLog = {}
    local old = buf
    buf = {}
    for _, e in ipairs(list) do bufferAdd(e) end
    for _, e in ipairs(old) do bufferAdd(e) end
end

function net.pendingEvents() return #buf, dropped end

-- Sending --------------------------------------------------------------------

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function stampHop(msg)
    local h, via = net.hop()
    msg.ohop = h
    msg.hop = (relayMode ~= "off") and h or nil
    msg.via = via
    msg.mk = modem.kind
end

function net.send(kind, to, body)
    if not net.online() then return false end   -- blind turtle: no work at all
    seq = seq + 1
    local msg = {}
    if type(body) == "table" then
        for k, v in pairs(body) do msg[k] = v end
    end
    msg.v, msg.kind, msg.from = 1, kind, myId
    msg.to = to or "server"
    msg.boot, msg.seq, msg.ts, msg.hops = bootId, seq, now(), 0
    stampHop(msg)
    if mesh and (kind == "status" or kind == "hello") then
        local okS, vs = pcall(mesh.summary)
        if okS then msg.vs = vs end
        local okU, us = pcall(mesh.stateText)
        if okU then msg.us = us end
    end
    signer.sign(msg)
    ringAdd(seen, tostring(myId) .. ":" .. tostring(bootId) .. ":" .. tostring(seq), msg.sig)
    -- Broadcast so every server (and relay) hears it; `to` says who it's for.
    local ok = pcall(rednet.broadcast, msg, PROTO)
    return ok
end

-- Events: sent at once in contact (kept until confirmed), buffered for `catchup` otherwise.
function net.event(level, text)
    if not net.online() then return false end
    evSeq = evSeq + 1
    local e = { eid = myId .. ":" .. bootId .. ":" .. evSeq, ts = now(), level = level or "info",
                text = string.sub(tostring(text), 1, 200) }
    if net.inContact() then
        e.sentAt = e.ts
        sentLog[#sentLog + 1] = e
        while #sentLog > CATCHUP_MAX do table.remove(sentLog, 1) end
        return net.send("event", "server", { level = e.level, text = e.text, eid = e.eid })
    end
    bufferAdd(e)
    return false
end

local function sendCatchup()
    if #buf == 0 then return end
    local list, t = {}, now()
    for _, b in ipairs(buf) do
        list[#list + 1] = { eid = b.eid, ts = b.ts, last = b.last, n = b.n, level = b.level, text = b.text }
        b.sentAt = t
        sentLog[#sentLog + 1] = b
    end
    while #sentLog > 2 * CATCHUP_MAX do table.remove(sentLog, 1) end
    net.send("catchup", "server", { events = list, dropped = dropped })
    buf, dropped = {}, 0
end

local function ack(to, id, ok, err)
    net.send("ack", to or "server", { id = id, ok = ok and true or false, err = err })
end

-- Relaying -------------------------------------------------------------------------
-- Every relay waits a small random delay; a copy heard meanwhile from a node that already
-- moved the message as far (or an ender modem, which everyone hears) cancels ours.

local pendingRelay, relayTimers = {}, {}
net.stats = { relayed = 0, cancelled = 0, bad = 0, lastBad = nil }

local function knownHop(id)
    local e = id and nodeHop[id]
    if e and now() - e.t <= 10 * CONTACT_MS then return e.hop end
    return nil
end

-- Returns the relay mode ("ender"|"flood"|"up"|"down") or nil.
local function relayModeFor(msg, myHop)
    if relayMode == "off" or modem.kind == "none" then return nil end
    if (tonumber(msg.hops) or 0) >= MAX_HOPS then return nil end
    local senderEnder = msg.mk == "ender" and not modem.wired   -- everyone already heard it
    if modem.kind == "ender" then return (not senderEnder) and "ender" or nil end
    if relayMode == "on" then return (not senderEnder) and "flood" or nil end
    if senderEnder or myHop == nil then return nil end
    local to = msg.to
    if to == "all" then return nil end
    local senderHop = tonumber(msg.hop)
    local dest
    if to == "server" then dest = 0 else dest = knownHop(tonumber(to)) end
    if dest == nil then
        if msg.ohop == 0 then return nil end   -- from a server to someone we don't know
        dest = 0                               -- from a turtle/pocket: towards the server
    end
    if dest == 0 then
        if senderHop == nil or myHop < senderHop then return "up" end
        return nil
    end
    if myHop < dest and (senderHop == nil or senderHop <= myHop) then return "down" end
    return nil
end

local function scheduleRelay(key, msg, mode)
    if pendingRelay[key] then return end
    local okT, id = pcall(os.startTimer, 0.05 + math.random() * 0.3)
    if not okT then return end
    pendingRelay[key] = { msg = copy(msg), mode = mode, timer = id }
    relayTimers[id] = key
end

local function maybeCancel(key, dup)
    local p = pendingRelay[key]
    if not p then return end
    local myHop = net.hop()
    local h = tonumber(dup.hop)
    local cancel = false
    if dup.mk == "ender" and not modem.wired then cancel = true
    elseif p.mode == "up" then cancel = h ~= nil and myHop ~= nil and h <= myHop
    elseif p.mode == "down" then cancel = h ~= nil and myHop ~= nil and h >= myHop
    elseif p.mode == "ender" then cancel = dup.mk == "ender" end
    if cancel then
        pendingRelay[key] = nil
        relayTimers[p.timer] = nil
        pcall(os.cancelTimer, p.timer)
        net.stats.cancelled = net.stats.cancelled + 1
    end
end

local function fireRelay(timerId)
    local key = relayTimers[timerId]
    if not key then return false end
    relayTimers[timerId] = nil
    local p = pendingRelay[key]
    pendingRelay[key] = nil
    if p and net.online() then
        local c = p.msg
        c.hops = (tonumber(c.hops) or 0) + 1
        local h, via = net.hop()
        c.hop, c.via, c.mk = h, via, modem.kind
        if pcall(rednet.broadcast, c, PROTO) then net.stats.relayed = net.stats.relayed + 1 end
    end
    return true
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

-- What a heard message tells us about distances and contact.
local function learn(sender, msg)
    local h = tonumber(msg.hop)
    local hops = tonumber(msg.hops) or 0
    if h == nil and msg.hop == nil and msg.ohop == nil and hops == 0 and SERVER_KINDS[msg.kind] then h = 0 end
    local t = now()
    if h and h >= 0 and h < HOP_LIMIT and type(sender) == "number" and sender ~= myId and msg.via ~= myId then
        neigh[sender] = { hop = h, t = t }
        everHeard = true
        lastHeard = t
        confirmSent(t - 1000)
    end
    local oh = tonumber(msg.ohop)
    if oh == nil and hops == 0 then oh = h end
    if oh and type(msg.from) == "number" then nodeHop[msg.from] = { hop = oh, t = t } end
end

-- Idempotent: both net.run and net.request may call it for the same event;
-- the dedupe ring makes sure each message is processed once.
local function handle(msg, sender)
    if type(msg) ~= "table" or msg.v ~= 1 or type(msg.kind) ~= "string" then return end
    if type(msg.hops) == "number" and msg.hops > MAX_HOPS then return end
    if not signer then return end
    local key = tostring(msg.from) .. ":" .. tostring(msg.boot) .. ":" .. tostring(msg.seq)
    local known = seen.set[key]
    if known ~= nil then
        -- A copy of a message we already checked: only the same signature counts.
        if known == msg.sig then
            if sender ~= nil then learn(sender, msg) end
            maybeCancel(key, msg)
        end
        return
    end
    local bkey = key .. "|" .. tostring(msg.sig)
    if ringHas(badSeen, bkey) then net.stats.bad = net.stats.bad + 1; return end
    local okS, why = signer.check(msg, now())
    if not okS then
        ringAdd(badSeen, bkey)
        net.stats.bad = net.stats.bad + 1
        net.stats.lastBad = tostring(why) .. " " .. tostring(msg.kind) .. " #" .. tostring(msg.from)
        return
    end
    ringAdd(seen, key, msg.sig)
    if sender ~= nil then learn(sender, msg) end
    if msg.from == myId then return end
    local to = msg.to
    if to ~= myId and tonumber(to) ~= myId then
        local mode = relayModeFor(msg, (net.hop()))
        if mode then scheduleRelay(key, msg, mode) end
    end
    if mesh and type(msg.vs) == "table" then pcall(mesh.heard, msg.from, msg.vs) end
    if to ~= "all" and tonumber(to) ~= myId then return end
    if mesh and Mesh.KINDS[msg.kind] then
        local okM, err = pcall(mesh.handle, msg)
        if not okM then net.stats.meshErr = tostring(err) end
        return
    end
    local hk = kindHooks[msg.kind]
    if hk then pcall(hk, msg) end
    if msg.kind == "cmd" then
        handleCmd(msg)
    elseif waiting[msg.kind] and waiting[msg.kind] > 0 then
        -- Several servers may answer; a found=true reply beats found=false.
        local prev = replies[msg.kind]
        if not (prev and prev.found and not msg.found) then replies[msg.kind] = msg end
        os.queueEvent(EV_REPLY, msg.kind)
    end
end

-- GPS samples (docs/CLUSTER_GPS_PLAN.md CG-3b): a turtle that knows its world position (posFn)
-- records the raw-modem distance to each server PC it hears directly and sends them, so the
-- server PCs can anchor a GPS constellation without asking anyone.
local posFn, gsamp, gsLast, gsSent = nil, {}, {}, 0
function net.gpsHost() return GpsMobile ~= nil and GpsMobile.active() end
function net.setGpsPos(fn) posFn = fn end
local function gpsSample(ev)
    local p, d = ev[5], ev[6]
    if not posFn or type(p) ~= "table" or p.sProtocol ~= PROTO or type(d) ~= "number" then return end
    local m = p.message
    if type(m) ~= "table" or m.hops ~= 0 or m.hop ~= 0 or m.from ~= ev[4]
        or (m.kind ~= "fleet" and m.kind ~= "cluster_hello") then return end
    local ok, pos = pcall(posFn)
    if not ok or type(pos) ~= "table" then return end
    local l = gsLast[m.from]
    if l and math.abs(l.x - pos.x) + math.abs(l.y - pos.y) + math.abs(l.z - pos.z) < 2 then return end
    gsLast[m.from] = { x = pos.x, y = pos.y, z = pos.z }
    gsamp[#gsamp + 1] = { id = m.from, x = pos.x, y = pos.y, z = pos.z, d = d }
    if #gsamp > 24 then table.remove(gsamp, 1) end
end

local function onEvent(ev)
    local e = ev[1]
    if e == "rednet_message" and ev[4] == PROTO then
        handle(ev[3], ev[2])
    elseif e == "timer" then
        fireRelay(ev[2])
    elseif e == "modem_message" then
        if GpsMobile and ev[3] == 65534 then pcall(GpsMobile.onMessage, ev) end
        gpsSample(ev)
        -- A basic-modem sender heard from beyond any basic range: our modem is an ender modem.
        local p, d = ev[5], ev[6]
        if not modem.inferred and type(p) == "table" and p.sProtocol == PROTO and type(p.message) == "table"
            and p.message.mk == "basic" and type(d) == "number" and d > FAR then
            modem.inferred = true
            updateKind()
        end
    end
end

-- Queue a command typed on the turtle itself (no network needed).
local localSeq = 0
function net.pushLocal(cmd, params)
    localSeq = localSeq + 1
    inbox[#inbox + 1] = { id = "local-" .. localSeq, cmd = cmd, params = params or {}, isLocal = true }
end

function net.poll()
    if #inbox == 0 then return nil end
    return table.remove(inbox, 1)
end

function net.statusNow()
    statusWanted = true
    os.queueEvent(EV_STATUS)
end

-- The mesh update engine (nil without a network or tmmesh.lua).
function net.mesh() return mesh end

local function meshTick()
    if not mesh then return end
    local ok, err = pcall(mesh.tick)
    if not ok then net.stats.meshErr = tostring(err) end
end

function net.init(c)
    if type(c) == "table" then cfg = c end
    if _G then _G.TMINER_NET = net end     -- debugging (lua> TMINER_NET.mesh()) and the simulator
    loadNetwork()
    readOverrides()
    openModems()
    if GpsMobile then pcall(GpsMobile.open) end
    mesh = nil
    if Mesh and signer and netKey then
        local okM, e = pcall(function()
            return Mesh.new({ role = "turtle", key = netKey, crypto = crypto, myId = myId,
                send = function(kind, to, body) return net.send(kind, to, body) end,
                log = function(text) net.event("info", "update: " .. tostring(text)) end,
                announce = function() net.statusNow() end }).init()
        end)
        if okM then mesh = e else net.stats.meshErr = tostring(e) end
    end
    if net.online() then return true end
    if not signer then return false, "no mining network (run install --network)" end
    return false, "no modem"
end

function net.setValidator(fn) validator = fn end
function net.onKind(kind, fn) kindHooks[kind] = fn end

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
        local r = replies[replyKind]
        -- A found=false answer may be beaten by another server; keep waiting.
        if r and r.found ~= false then result = r; break end
        local ev = { os.pullEvent() }
        if ev[1] == "timer" and ev[2] == timer then result = replies[replyKind]; break end
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
    if not net.online() then return end   -- nobody to tell: don't build the status table
    if not net.inContact() then statusDeferred = true; return end
    statusDeferred = false
    local ok, st = pcall(getStatus)
    if ok and type(st) == "table" then net.send("status", "server", st) end
end

-- Contact came back: catch-up log first, then the newest status. Contact lost: events sent
-- since we last heard anyone may not have arrived; keep them for the catch-up.
local wasContact = nil
local function checkContact(getStatus)
    if not net.online() then return end
    local c = net.inContact()
    if c and wasContact == false then
        sendCatchup()
        if statusDeferred then statusWanted = true end
    elseif c and #buf > 0 and net.hop() then
        sendCatchup()
    elseif not c and wasContact then
        rebufferSent()
    end
    wasContact = c
end

-- Coroutine body. Never returns (except by "Terminated").
function net.run(getStatus)
    local timer = os.startTimer(interval())
    local hk = net.online() and os.startTimer(HOUSEKEEP) or nil
    wasContact = net.inContact()
    sendStatus(getStatus)
    while true do
        local ev = { os.pullEvent() }
        local e = ev[1]
        if e == "timer" and ev[2] == timer then
            statusWanted = true
            timer = os.startTimer(interval())
        elseif e == "timer" and ev[2] == hk then
            hk = net.online() and os.startTimer(HOUSEKEEP) or nil
            meshTick()
        elseif e == "peripheral" or e == "peripheral_detach" then
            openModems()
            if not hk and net.online() then hk = os.startTimer(HOUSEKEEP) end
        else
            onEvent(ev)
        end
        checkContact(getStatus)
        if #gsamp > 0 and now() - gsSent >= 15000 and net.inContact() then
            net.send("gps_sample", "server", { s = gsamp })
            gsamp, gsSent = {}, now()
        end
        if statusWanted then
            statusWanted = false
            sendStatus(getStatus)
        end
    end
end

return net
