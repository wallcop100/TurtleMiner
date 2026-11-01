-- Version: 1.0.0
-- TurtleMiner server, radio part: TMINER envelope, dedupe, modems, relaying (mesh across
-- wired / wireless / ender, docs/COMMS.md), the turtle protocol (docs/PROTOCOL.md) and the
-- `fleet` heartbeat. Loaded into the shared table T after tm_db.lua.
-- Cluster rule: every server PC relays; only the leader acts on turtle messages (homes,
-- commands, log), so turtles see one server however many PCs there are.
local T = ...
local S = T.S

local PROTO          = "TMINER"
local MAX_HOPS       = 4
local FLEET_EVERY_MS = 5000
T.PROTO = PROTO

-- Kinds only turtles send: hearing one means the turtle is reachable right now.
local TURTLE_KINDS = {
    status = true, hello = true, event = true, ack = true, home_save = true, home_get = true,
    home_clear = true, away = true, catchup = true, update_check = true, file_get = true,
}
-- Phases at home: an `away` announcement is over.
local HOME_PHASES = { UNLOADING = true, REFUELING = true, IDLE = true, DONE = true }
local ENVELOPE = { v = true, kind = true, to = true, boot = true, seq = true, hops = true, ts = true, from = true }

local now, copy, trunc = T.now, T.copy, T.trunc

-- ---------------------------------------------------------------------------
-- Envelope, dedupe, modems
-- ---------------------------------------------------------------------------
local function markSeen(key)
    if S.seen[key] then return false end
    S.seenPos = S.seenPos % T.DEDUPE_MAX + 1
    local old = S.seenQ[S.seenPos]
    if old then S.seen[old] = nil end
    S.seenQ[S.seenPos] = key
    S.seen[key] = true
    return true
end

function T.send(kind, to, body)
    local msg = body and copy(body) or {}
    S.seq = S.seq + 1
    msg.v, msg.kind, msg.from, msg.to = 1, kind, S.myId, to
    msg.boot, msg.seq, msg.ts, msg.hops = S.boot, S.seq, now(), 0
    -- Distance to the server (docs/COMMS.md): a server is 0; a pocket doesn't relay (no `hop`).
    if S.mode == "server" then msg.hop, msg.ohop = 0, 0 end
    msg.mk = S.modemKind
    markSeen(msg.from .. ":" .. msg.boot .. ":" .. msg.seq)
    if S.netOk then pcall(rednet.broadcast, msg, PROTO) end
    return msg
end
local send = T.send

-- Own modem kind: wired / basic / ender. A computer can't tell an ender modem from a basic
-- one, so wireless counts as basic unless setting tminer.MODEM says otherwise or we hear a
-- basic-modem sender from beyond any basic range (only an ender receiver can).
local function updateKind(wireless, wired)
    local o = settings and settings.get and settings.get("tminer.MODEM")
    if o == "ender" or o == "basic" or o == "wired" then S.modemKind = o
    elseif wireless then S.modemKind = S.inferredEnder and "ender" or "basic"
    elseif wired then S.modemKind = "wired"
    else S.modemKind = "none" end
end

function T.openModems()
    local any, wireless, wired = false, false, false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local okW, w = pcall(peripheral.call, name, "isWireless")
            if okW and w then wireless = true else wired = true end
            if pcall(rednet.open, name) then any = true end
        end
    end
    S.hasWired, S.hasWireless = wired, wireless
    updateKind(wireless, wired)
    S.netOk = any or (rednet.isOpen and rednet.isOpen()) or false
    return S.netOk
end

-- ---------------------------------------------------------------------------
-- Turtle messages (leader; a pocket builds its view from `fleet`)
-- ---------------------------------------------------------------------------
local function stripEnvelope(msg)
    local t = {}
    for k, v in pairs(msg) do if not ENVELOPE[k] then t[k] = v end end
    return t
end

local function onStatus(msg)
    local r = T.getRec(msg.from, true)
    local old = r.st.phase
    r.st = stripEnvelope(msg)
    r.st.hop, r.st.ohop, r.st.via, r.st.mk = nil, nil, nil, nil
    r.mk = msg.mk
    if HOME_PHASES[r.st.phase] and r.away then
        r.away = nil
        T.logLine(T.nameOf(r) .. ": back home")
    end
    r.lastSeen = now()
    if old ~= r.st.phase then
        T.logLine(T.nameOf(r) .. ": " .. tostring(old or "?") .. " -> " .. tostring(r.st.phase)
            .. (r.st.reason and (" (" .. r.st.reason .. ")") or ""))
    end
    T.updateAlerts(r.lastSeen)
end

local function onHello(msg)
    local r = T.getRec(msg.from, true)
    if msg.label then r.st.label = msg.label end
    if msg.version then r.st.version = msg.version end
    if msg.gps ~= nil then r.st.gps = msg.gps end
    r.lastSeen = now()
    T.logLine(T.nameOf(r) .. ": online v" .. tostring(msg.version) .. (msg.gps and " gps" or " no-gps"))
end

local function onEvent(msg)
    local r = T.getRec(msg.from, true)
    r.lastSeen = now()
    if not T.eventNew(msg.eid) then return end
    local text = trunc(msg.text, 200)
    table.insert(r.events, 1, { level = msg.level, text = text, at = r.lastSeen })
    while #r.events > 5 do table.remove(r.events) end
    T.logLine(T.nameOf(r) .. " [" .. tostring(msg.level or "info") .. "] " .. text)
end

-- Expected absence: ETA from the turtle's own estimate, measured on the server clock.
local function onAway(msg)
    local r = T.getRec(msg.from, true)
    local t = now()
    r.lastSeen = t
    if msg.label then r.st.label = msg.label end
    local est = tonumber(msg.est)
    local eta = est and (t + est * 1000) or tonumber(msg.eta)
    if not eta then return end
    r.away = { since = t, eta = eta }
    T.logLine(T.nameOf(r) .. ": " .. T.awayText(r))
    T.markDirty()
end

-- Catch-up log: events buffered while out of contact, merged with their original times.
local function onCatchup(msg)
    local r = T.getRec(msg.from, true)
    r.lastSeen = now()
    if type(msg.events) ~= "table" then return end
    local lines = {}
    for _, e in ipairs(msg.events) do
        if type(e) == "table" and type(e.text) == "string" and T.eventNew(e.eid) then
            local ms = tonumber(e.ts) or now()
            local n = tonumber(e.n) or 1
            local text = trunc(e.text, 200) .. (n > 1 and (" (x" .. n .. ")") or "")
            lines[#lines + 1] = { ms = ms, text = T.nameOf(r) .. " [" .. tostring(e.level or "info") .. "] " .. text .. " (catch-up)" }
            T.addEvent(r, e.level, text, tonumber(e.last) or ms)
        end
    end
    local dropped = tonumber(msg.dropped) or 0
    if dropped > 0 then
        lines[#lines + 1] = { ms = now(), text = T.nameOf(r) .. " [warn] " .. dropped .. " older events dropped while out of contact" }
    end
    T.logMerge(lines)
end

-- Pocket: merge a fleet snapshot (newest lastSeen wins per turtle).
local function onFleet(msg)
    if type(msg.turtles) ~= "table" then return end
    S.fleetFrom = (type(msg.server) == "table" and tonumber(msg.server.id)) or msg.from
    S.fleetLabel = type(msg.server) == "table" and msg.server.label or nil
    S.fleetAt = now()
    for _, t in ipairs(msg.turtles) do
        local id = type(t) == "table" and tonumber(t.id)
        if id then
            local r = T.getRec(id, true)
            local ls = tonumber(t.lastSeen) or 0
            if ls >= r.lastSeen then
                local st = copy(t)
                st.id, st.lastSeen, st.alert, st.away, st.queued = nil, nil, nil, nil, nil
                r.st = st
                r.lastSeen = ls
                r.away = type(t.away) == "table" and tonumber(t.away.since) and tonumber(t.away.eta)
                    and { since = t.away.since, eta = t.away.eta } or nil
                r.queued = tonumber(t.queued)
            end
        end
    end
    T.updateAlerts(now())
    T.markDirty()
end

-- A pocket's command: the leader issues it; any other server PC forwards it to the leader.
local function onCmdRelay(msg)
    if msg.to ~= S.myId then return end
    local target, id = tonumber(msg.target), msg.id
    if not target or type(id) ~= "string" then return end
    if not T.CMDS[msg.cmd] then
        send("ack", msg.from, { id = id, ok = false, err = "unknown cmd", target = target })
        return
    end
    local p = S.pending[id]
    if p and T.isLeader() then
        p.origin = msg.from
        if p.queued then send("ack", msg.from, { id = id, queued = true, target = p.target }) end
        return
    end
    local d = S.done[id]
    if d then
        send("ack", msg.from, { id = id, ok = d.ok, err = d.err, target = d.target })
        return
    end
    T.issueCmd(target, msg.cmd, type(msg.params) == "table" and msg.params or {}, msg.from, id)
end

-- Home records (leader only: one answer per turtle, docs/PROTOCOL.md)
local function onHomeSave(msg)
    if type(msg.home) ~= "table" then return end
    local r = T.getRec(msg.from, false)
    S.homes[msg.from] = { home = msg.home, homeFacing = msg.homeFacing, gps = msg.gps == true,
        label = r and r.st.label, at = now() }
    S.dH[msg.from] = true
    T.saveHomes()
    local h = msg.home
    T.logLine("HOME #" .. msg.from .. " saved " .. tostring(h.x) .. "," .. tostring(h.y) .. "," .. tostring(h.z))
end

local function onHomeClear(msg)
    if S.homes[msg.from] == nil then return end
    S.homes[msg.from] = nil
    S.dH[msg.from] = true
    T.saveHomes()
    T.logLine("HOME #" .. msg.from .. " cleared (reinstalled)")
end

local function onHomeGet(msg)
    local h = S.homes[msg.from]
    if h then
        send("home", msg.from, { found = true, home = h.home, homeFacing = h.homeFacing, gps = h.gps })
    else
        send("home", msg.from, { found = false })
    end
end

-- ---------------------------------------------------------------------------
-- Message entry point
-- ---------------------------------------------------------------------------
local function relay(msg, hops)
    if S.mode ~= "server" or hops >= MAX_HOPS or not S.netOk then return end
    -- A copy from an ender modem was heard by every wireless modem already.
    if msg.mk == "ender" and not S.hasWired then return end
    -- Fleets: only the cluster leader's, so turtles near any gateway hear the one server.
    if msg.kind == "fleet" and (T.isLeader() or not T.C or msg.from ~= T.C.leader) then return end
    local c = copy(msg)
    c.hops = hops + 1
    c.hop, c.via, c.mk = 0, nil, S.modemKind
    pcall(rednet.broadcast, c, PROTO)
end

function T.handleMessage(sender, msg, protocol)
    if protocol ~= PROTO or type(msg) ~= "table" then return end
    if msg.v ~= 1 or type(msg.kind) ~= "string" or type(msg.from) ~= "number"
        or type(msg.boot) ~= "number" or type(msg.seq) ~= "number" then return end
    local hops = tonumber(msg.hops) or 0
    if hops > MAX_HOPS or msg.from == S.myId then return end
    if not markSeen(msg.from .. ":" .. msg.boot .. ":" .. msg.seq) then return end
    relay(msg, hops)

    local k = msg.kind
    if k:sub(1, 8) == "cluster_" then
        if S.mode == "server" and T.clusterMessage then T.clusterMessage(msg) end
        return
    end
    local leader = T.isLeader()
    if S.mode == "pocket" then
        if k == "fleet" then onFleet(msg); T.markDirty(); return end
    else
        if (k == "update_check" or k == "file_get") and T.updateMessage then T.updateMessage(msg) end
        if k == "cmd_relay" then onCmdRelay(msg); T.markDirty(); return end
        if not leader then return end
        -- Any message from a turtle: it is reachable now, deliver its queued commands.
        if TURTLE_KINDS[k] then
            local r = T.getRec(msg.from, false)
            if r then
                r.lastSeen = now()
                T.deliverQueued(r)
            end
        end
    end
    if k == "status" then onStatus(msg)
    elseif k == "away" then onAway(msg)
    elseif k == "catchup" then onCatchup(msg)
    elseif k == "hello" then onHello(msg)
    elseif k == "event" then onEvent(msg)
    elseif k == "ack" then
        local r = T.getRec(msg.from, false)
        if r then r.lastSeen = now() end
        T.onAck(msg)
    elseif leader and k == "home_save" then onHomeSave(msg)
    elseif leader and k == "home_get" then onHomeGet(msg)
    elseif leader and k == "home_clear" then onHomeClear(msg)
    else
        local r = T.getRec(msg.from, false)
        if r then r.lastSeen = now() end
    end
    if S.turtles[msg.from] then T.touch(msg.from) end
    T.markDirty()
end

-- Leader: the heartbeat that keeps turtles in contact, and the pockets' view.
function T.sendFleet(t)
    local arr = {}
    for id, r in pairs(S.turtles) do
        local e = copy(r.st)
        e.id, e.lastSeen, e.alert = id, r.lastSeen, r.alert
        e.away = r.away
        local q = 0
        for _, p in pairs(S.pending) do if p.target == id and p.queued then q = q + 1 end end
        e.queued = q > 0 and q or nil
        arr[#arr + 1] = e
    end
    table.sort(arr, function(a, b) return a.id < b.id end)
    local label = os.getComputerLabel and os.getComputerLabel() or nil
    send("fleet", "all", { turtles = arr, server = { id = S.myId, label = label } })
    S.lastFleet = t
end

function T.tickRadio(t)
    if T.isLeader() and t - S.lastFleet >= FLEET_EVERY_MS then T.sendFleet(t) end
end

function T.netLoop()
    while true do
        local ev = { os.pullEvent() }
        if ev[1] == "rednet_message" then
            T.handleMessage(ev[2], ev[3], ev[4])
        elseif ev[1] == "modem_message" and not S.inferredEnder then
            -- A basic-modem sender heard from beyond any basic range: ours is an ender modem.
            local p, d = ev[5], ev[6]
            if type(p) == "table" and p.sProtocol == PROTO and type(p.message) == "table"
                and p.message.mk == "basic" and type(d) == "number" and d > 400 then
                S.inferredEnder = true
                T.openModems()
                T.markDirty()
            end
        end
    end
end

return T
