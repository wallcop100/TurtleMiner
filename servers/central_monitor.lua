-- Version: 4.2.0
-- TurtleMiner central monitor. Speaks TMINER v1 only (docs/PROTOCOL.md, docs/COMMS.md).
--   Server mode (normal computer): relays TMINER traffic between all modems, tracks turtles,
--     keeps home records, broadcasts `fleet`, sends commands to one turtle at a time.
--     Commands to a turtle it hasn't heard lately are queued and delivered when it is next
--     heard (store-and-forward). Turtles out of modem range announce `away` with an ETA; the
--     monitor alerts only when they are overdue. Their `catchup` logs are merged by time.
--   Pocket mode (`pocket` global present): read-only view built from `fleet` snapshots,
--     commands go out as `cmd_relay` through the server.
-- Usage: central_monitor [monitorSide|auto|none] [textScale]

local M = {}

-- Store-and-forward / expected absence (docs/COMMS.md rules 2 and 3)
local QUEUE_EXPIRE_MS  = 24 * 3600 * 1000   -- queued commands are dropped after this
local HEARD_MS         = 30000              -- heard within this: send commands at once
local OVERDUE_FACTOR   = 1.5                -- alert when away longer than ETA * factor + grace
local OVERDUE_GRACE_MS = 120000

local PROTO            = "TMINER"
local MAX_HOPS         = 4
local DEDUPE_MAX       = 256
local SILENT_MS        = 60000
local FLEET_EVERY_MS   = 5000
local ACK_TIMEOUT_MS   = 3000
local ACK_RETRIES      = 3       -- server: 1 send + 3 retries
local RELAY_TIMEOUT_MS = 15000   -- pocket: server needs up to 12 s before it reports a failure
local RELAY_RETRIES    = 1
local DONE_KEEP_MS     = 60000
local TICK             = 0.5
local HOME_FILE        = "miner_homes.db"
local LOG_FILE         = "miner_events.log"
local LOG_MAX          = 500
local LOG_KEEP         = 400
local EVENTS_KEEP      = 5

local CMDS = {
    RETURN_HOME = true, PAUSE = true, RESUME = true, SET = true, REQUEST_STATUS = true,
    RESET_JOB = true, RESET_HOME = true, UPDATE = true, REBOOT = true,
}
local FOCUS_LIST = {
    "all", "diamond", "iron", "gold", "copper", "redstone", "lapis",
    "emerald", "coal", "ancient_debris", "nether_quartz", "nether_gold",
}
-- Keys the turtle accepts with SET (miner/config.lua REMOTE_KEYS). The monitor can't
-- load config.lua, so the list lives here too: {key, short label, type, min, max}.
local SET_KEYS = {
    { "TARGET_Y",        "TARGET_Y",    "number", -64, 320 },
    { "HOME_Y",          "HOME_Y",      "number", -64, 320 },
    { "BRANCH_LENGTH",   "BRANCH_LEN",  "number", 4, 128 },
    { "BRANCH_SPACING",  "BRANCH_SPC",  "number", 2, 8 },
    { "MAIN_LENGTH",     "MAIN_LEN",    "number", 8, 256 },
    { "MAX_CORRIDORS",   "CORRIDORS",   "number", 1, 64 },
    { "FOCUS",           "FOCUS",       "string" },
    { "VEIN_MINING",     "VEIN_MINING", "bool" },
    { "VEIN_MAX",        "VEIN_MAX",    "number", 1, 512 },
    { "DROP_TRASH",      "DROP_TRASH",  "bool" },
    { "FUEL_MARGIN",     "FUEL_MARGIN", "number", 0, 10000 },
    { "FUEL_KEEP",       "FUEL_KEEP",   "number", 0, 64 },
    { "FUEL_TARGET",     "FUEL_TARGET", "number", 0, 100000 },
    { "BURN_COAL",       "BURN_COAL",   "bool" },
    { "STATUS_INTERVAL", "STATUS_INT",  "number", 2, 120 },
    { "AUTO_UPDATE",     "AUTO_UPDATE", "bool" },
    { "SURFACE_IF_LOST", "SURF_LOST",   "bool" },
}
M.SET_KEYS = SET_KEYS
local PHASE_SHORT = {
    BOOT = "BOOT", RECOVER = "RECOVR", TO_WORK = "TOWORK", MINING = "MINING", VEIN = "VEIN",
    RETURNING = "RETURN", UNLOADING = "UNLOAD", REFUELING = "REFUEL", IDLE = "IDLE",
    PAUSED = "PAUSED", NEEDS_HELP = "HELP!", ERROR = "ERROR", DONE = "DONE", SILENT = "SILENT",
    AWAY = "AWAY", OVERDUE = "LATE!",
}
-- Kinds only turtles send: hearing one means the turtle is reachable right now.
local TURTLE_KINDS = {
    status = true, hello = true, event = true, ack = true, home_save = true, home_get = true,
    home_clear = true, away = true, catchup = true, update_check = true, file_get = true,
}
-- Phases at home: an `away` announcement is over.
local HOME_PHASES = { UNLOADING = true, REFUELING = true, IDLE = true, DONE = true }
local ENVELOPE = { v = true, kind = true, to = true, boot = true, seq = true, hops = true, ts = true, from = true }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local S = {
    mode = "server", myId = 0, boot = 0, seq = 0, netOk = false,
    seen = {}, seenQ = {}, seenPos = 0,
    turtles = {}, pending = {}, done = {}, homes = {},
    log = {}, cmdCounter = 0, lastFleet = 0, lastDirtyTick = 0,
    fleetFrom = nil, fleetLabel = nil, fleetAt = 0,
    uis = {}, dirtyQueued = false,
    modemKind = "none", hasWired = false, inferredEnder = false,
    evSeen = {}, evSeenQ = {}, evSeenPos = 0,
}
M.S = S

local function now() return os.epoch("utc") end

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function trunc(s, n)
    s = tostring(s or "")
    if n < 1 then return "" end
    if #s > n then return s:sub(1, n) end
    return s
end

local function pad(s, n) s = trunc(s, n); return s .. string.rep(" ", n - #s) end
local function lpad(s, n) s = trunc(s, n); return string.rep(" ", n - #s) .. s end

local function markDirty()
    if not S.dirtyQueued then
        S.dirtyQueued = true
        if os.queueEvent then os.queueEvent("tminer_redraw") end
    end
end

-- ---------------------------------------------------------------------------
-- Files (atomic write: tmp + move)
-- ---------------------------------------------------------------------------
local function writeAtomic(path, text)
    local tmp = path .. ".tmp"
    local h = fs.open(tmp, "w")
    if not h then return false end
    h.write(text)
    h.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local s = h.readAll()
    h.close()
    return s
end

local function loadHomes()
    for _, p in ipairs({ HOME_FILE, HOME_FILE .. ".tmp" }) do
        local s = readFile(p)
        local t = s and textutils.unserialize(s)
        if type(t) == "table" then return t end
    end
    return {}
end

local function saveHomes()
    pcall(writeAtomic, HOME_FILE, textutils.serialize(S.homes))
end

-- ---------------------------------------------------------------------------
-- Event log (server: file, rotating; pocket: memory only)
-- ---------------------------------------------------------------------------
local function stamp(ms)
    local ok, s = pcall(os.date, "!%m-%d %H:%M:%S", math.floor(ms / 1000))
    return ok and s or tostring(math.floor(ms / 1000))
end

local function loadLog()
    local s = readFile(LOG_FILE)
    if not s then return end
    for line in s:gmatch("[^\n]+") do S.log[#S.log + 1] = line end
    while #S.log > LOG_MAX do table.remove(S.log, 1) end
end

local function logLine(text)
    local line = stamp(now()) .. " " .. text
    S.log[#S.log + 1] = line
    if #S.log > LOG_MAX then
        local keep = {}
        for i = #S.log - LOG_KEEP + 1, #S.log do keep[#keep + 1] = S.log[i] end
        S.log = keep
        if S.mode == "server" then pcall(writeAtomic, LOG_FILE, table.concat(S.log, "\n") .. "\n") end
    elseif S.mode == "server" then
        pcall(function()
            local h = fs.open(LOG_FILE, "a")
            if h then h.write(line .. "\n"); h.close() end
        end)
    end
    markDirty()
end
M.logLine = logLine

-- Merge lines with their original times (catch-up logs): sorted insert, then one file rewrite.
local function logMerge(entries)
    if #entries == 0 then return end
    table.sort(entries, function(a, b) return a.ms < b.ms end)
    for _, e in ipairs(entries) do
        local line = stamp(e.ms) .. " " .. e.text
        local key = line:sub(1, 14)
        local i = #S.log
        while i >= 1 and S.log[i]:sub(1, 14) > key do i = i - 1 end
        table.insert(S.log, i + 1, line)
    end
    while #S.log > LOG_MAX do table.remove(S.log, 1) end
    if S.mode == "server" then pcall(writeAtomic, LOG_FILE, table.concat(S.log, "\n") .. "\n") end
    markDirty()
end
M.logMerge = logMerge

-- Clock text for an epoch-ms time, in the server's local time when os.epoch("local") exists.
local function clockText(ms)
    local off = 0
    local okL, l = pcall(os.epoch, "local")
    local okU, u = pcall(os.epoch, "utc")
    if okL and okU and type(l) == "number" and type(u) == "number" then
        off = math.floor((l - u) / 60000 + 0.5) * 60000
    end
    local ok, s = pcall(os.date, "!%H:%M", math.floor((ms + off) / 1000))
    return ok and s or "?"
end
M.clockText = clockText

-- ---------------------------------------------------------------------------
-- Network
-- ---------------------------------------------------------------------------
local function markSeen(key)
    if S.seen[key] then return false end
    S.seenPos = S.seenPos % DEDUPE_MAX + 1
    local old = S.seenQ[S.seenPos]
    if old then S.seen[old] = nil end
    S.seenQ[S.seenPos] = key
    S.seen[key] = true
    return true
end

local function send(kind, to, body)
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

local function openModems()
    local any, wireless, wired = false, false, false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local okW, w = pcall(peripheral.call, name, "isWireless")
            if okW and w then wireless = true else wired = true end
            if pcall(rednet.open, name) then any = true end
        end
    end
    S.hasWired = wired
    updateKind(wireless, wired)
    S.netOk = any or (rednet.isOpen and rednet.isOpen()) or false
    return S.netOk
end

-- ---------------------------------------------------------------------------
-- Turtle model
-- ---------------------------------------------------------------------------
local function getRec(id, create)
    local r = S.turtles[id]
    if not r and create then
        r = { id = id, st = {}, lastSeen = 0, events = {} }
        S.turtles[id] = r
    end
    return r
end

local function labelOf(r)
    return r.st.label or ("turtle " .. r.id)
end

local function nameOf(r) return labelOf(r) .. " #" .. r.id end

local function overdueAt(a)
    return a.since + math.floor((a.eta - a.since) * OVERDUE_FACTOR) + OVERDUE_GRACE_MS
end

-- Silent but announced `away` and not overdue: no alert (the card says "away, back by").
local function isAway(r, t)
    return r.away ~= nil and t - (r.lastSeen or 0) > SILENT_MS and t <= overdueAt(r.away)
end

local function awayText(r)
    if not r.away then return nil end
    return "away, back by ~" .. clockText(r.away.eta)
end

local function alertOf(r, t)
    if t - (r.lastSeen or 0) > SILENT_MS then
        if not r.away then return "SILENT" end
        if t > overdueAt(r.away) then return "OVERDUE" end
    end
    local ph = r.st.phase
    if ph == "NEEDS_HELP" or ph == "ERROR" then return ph end
    return nil
end

local function beep()
    local sp = peripheral.find and peripheral.find("speaker")
    if sp then pcall(sp.playNote, "bell", 3, 18) end
end

local function updateAlerts(t)
    for _, r in pairs(S.turtles) do
        local a = alertOf(r, t)
        if a ~= r.alert then
            if a then
                logLine("ALERT " .. nameOf(r) .. ": " .. a .. (r.st.reason and (" (" .. r.st.reason .. ")") or ""))
                beep()
            else
                logLine("OK " .. nameOf(r) .. ": alert " .. tostring(r.alert) .. " cleared")
            end
            r.alert = a
            markDirty()
        end
    end
end

local function stripEnvelope(msg)
    local t = {}
    for k, v in pairs(msg) do if not ENVELOPE[k] then t[k] = v end end
    return t
end

local function onStatus(msg)
    local r = getRec(msg.from, true)
    local old = r.st.phase
    r.st = stripEnvelope(msg)
    r.st.hop, r.st.ohop, r.st.via, r.st.mk = nil, nil, nil, nil
    r.mk = msg.mk
    if HOME_PHASES[r.st.phase] and r.away then
        r.away = nil
        logLine(nameOf(r) .. ": back home")
    end
    r.lastSeen = now()
    if old ~= r.st.phase then
        logLine(nameOf(r) .. ": " .. tostring(old or "?") .. " -> " .. tostring(r.st.phase)
            .. (r.st.reason and (" (" .. r.st.reason .. ")") or ""))
    end
    updateAlerts(r.lastSeen)
end

local function onHello(msg)
    local r = getRec(msg.from, true)
    if msg.label then r.st.label = msg.label end
    if msg.version then r.st.version = msg.version end
    if msg.gps ~= nil then r.st.gps = msg.gps end
    r.lastSeen = now()
    logLine(nameOf(r) .. ": online v" .. tostring(msg.version) .. (msg.gps and " gps" or " no-gps"))
end

-- Event ids (`eid`) seen: an event re-sent in a catch-up log is logged once.
local function eventNew(eid)
    if type(eid) ~= "string" then return true end
    if S.evSeen[eid] then return false end
    S.evSeenPos = S.evSeenPos % DEDUPE_MAX + 1
    local old = S.evSeenQ[S.evSeenPos]
    if old then S.evSeen[old] = nil end
    S.evSeenQ[S.evSeenPos] = eid
    S.evSeen[eid] = true
    return true
end

local function addEvent(r, level, text, at)
    local i = 1
    while r.events[i] and (r.events[i].at or 0) > at do i = i + 1 end
    table.insert(r.events, i, { level = level, text = text, at = at })
    while #r.events > EVENTS_KEEP do table.remove(r.events) end
end

local function onEvent(msg)
    local r = getRec(msg.from, true)
    r.lastSeen = now()
    if not eventNew(msg.eid) then return end
    local text = trunc(msg.text, 200)
    table.insert(r.events, 1, { level = msg.level, text = text, at = r.lastSeen })
    while #r.events > EVENTS_KEEP do table.remove(r.events) end
    logLine(nameOf(r) .. " [" .. tostring(msg.level or "info") .. "] " .. text)
end

-- Expected absence: ETA from the turtle's own estimate, measured on the server clock.
local function onAway(msg)
    local r = getRec(msg.from, true)
    local t = now()
    r.lastSeen = t
    if msg.label then r.st.label = msg.label end
    local est = tonumber(msg.est)
    local eta = est and (t + est * 1000) or tonumber(msg.eta)
    if not eta then return end
    r.away = { since = t, eta = eta }
    logLine(nameOf(r) .. ": " .. awayText(r))
    markDirty()
end

-- Catch-up log: events buffered while out of contact, merged with their original times.
local function onCatchup(msg)
    local r = getRec(msg.from, true)
    r.lastSeen = now()
    if type(msg.events) ~= "table" then return end
    local lines = {}
    for _, e in ipairs(msg.events) do
        if type(e) == "table" and type(e.text) == "string" and eventNew(e.eid) then
            local ms = tonumber(e.ts) or now()
            local n = tonumber(e.n) or 1
            local text = trunc(e.text, 200) .. (n > 1 and (" (x" .. n .. ")") or "")
            lines[#lines + 1] = { ms = ms, text = nameOf(r) .. " [" .. tostring(e.level or "info") .. "] " .. text .. " (catch-up)" }
            addEvent(r, e.level, text, tonumber(e.last) or ms)
        end
    end
    local dropped = tonumber(msg.dropped) or 0
    if dropped > 0 then
        lines[#lines + 1] = { ms = now(), text = nameOf(r) .. " [warn] " .. dropped .. " older events dropped while out of contact" }
    end
    logMerge(lines)
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
            local r = getRec(id, true)
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
    updateAlerts(now())
    markDirty()
end

-- ---------------------------------------------------------------------------
-- Commands (non-blocking: pending table, retries driven by tick)
-- ---------------------------------------------------------------------------
local function cmdText(cmd, params)
    if cmd == "SET" and type(params) == "table" then
        return tostring(params.key) .. "=" .. tostring(params.value)
    end
    return tostring(cmd)
end

local function newCmdId()
    S.cmdCounter = S.cmdCounter + 1
    return S.myId .. "-" .. S.boot .. "-" .. S.cmdCounter
end

local function finishCmd(p, ok, err)
    S.pending[p.id] = nil
    local r = getRec(p.target, true)
    r.cmd = { name = cmdText(p.cmd, p.params), state = ok and "ok" or "failed", err = err, at = now() }
    logLine("CMD " .. r.cmd.name .. " -> " .. nameOf(r) .. ": " .. (ok and "ok" or ("FAILED " .. tostring(err))))
    if S.mode == "server" then
        S.done[p.id] = { ok = ok, err = err, target = p.target, at = now() }
        if p.origin then send("ack", p.origin, { id = p.id, ok = ok, err = err, target = p.target }) end
    end
end

local function transmitCmd(p)
    if S.mode == "server" then
        send("cmd", p.target, { id = p.id, cmd = p.cmd, params = p.params })
        p.deadline = now() + ACK_TIMEOUT_MS
    else
        p.server = S.fleetFrom or p.server
        send("cmd_relay", p.server, { target = p.target, cmd = p.cmd, params = p.params, id = p.id })
        p.deadline = now() + RELAY_TIMEOUT_MS
    end
end

-- Store-and-forward: hold the command until the turtle is heard again (server), or until the
-- server reports it delivered (pocket).
local function queueCmd(p)
    p.queued = true
    p.deadline = math.huge
    local r = getRec(p.target, true)
    r.cmd = { name = cmdText(p.cmd, p.params), state = "queued", at = p.queuedAt or now() }
    local first = p.queuedAt == nil
    p.queuedAt = p.queuedAt or now()
    if S.mode == "server" and first then
        logLine("CMD " .. r.cmd.name .. " -> " .. nameOf(r) .. ": queued until it is heard")
        if p.origin then send("ack", p.origin, { id = p.id, queued = true, target = p.target }) end
    end
    markDirty()
end
M.queueCmd = queueCmd

-- The turtle was just heard: send what is queued for it (retried until acked).
local function deliverQueued(r)
    for _, p in pairs(S.pending) do
        if p.target == r.id and p.queued then
            p.queued = false
            p.tries = 1
            transmitCmd(p)
            r.cmd = { name = cmdText(p.cmd, p.params), state = "pending", tries = 1, at = now() }
            markDirty()
        end
    end
end

-- Same kind = same target and command (SET: same key). A newer one replaces the older.
local function sameKind(a, target, cmd, params)
    return a.target == target and a.cmd == cmd
        and (cmd ~= "SET" or (type(a.params) == "table" and type(params) == "table" and a.params.key == params.key))
end

-- Send one command to ONE turtle. Returns the command id.
function M.issueCmd(target, cmd, params, origin, id)
    id = id or newCmdId()
    params = params or {}
    local p = { id = id, target = target, cmd = cmd, params = params, tries = 1, origin = origin, created = now() }
    local r = getRec(target, true)
    if S.mode == "pocket" and not S.fleetFrom then
        r.cmd = { name = cmdText(cmd, p.params), state = "failed", err = "no server heard", at = now() }
        markDirty()
        return id
    end
    local old = {}
    for _, q in pairs(S.pending) do
        if q.id ~= id and sameKind(q, target, cmd, params) then old[#old + 1] = q end
    end
    for _, q in ipairs(old) do finishCmd(q, false, "replaced") end
    S.pending[id] = p
    if S.mode == "server" and now() - (r.lastSeen or 0) > HEARD_MS then
        queueCmd(p)
        return id
    end
    transmitCmd(p)
    r.cmd = { name = cmdText(cmd, p.params), state = "pending", tries = 1, at = now() }
    markDirty()
    return id
end

local function onAck(msg)
    local p = S.pending[msg.id]
    if not p then return end
    if S.mode == "server" then
        if msg.from ~= p.target then return end
    elseif msg.from ~= p.target and msg.from ~= p.server then
        return
    end
    if msg.queued then
        if S.mode == "pocket" then queueCmd(p) end
        return
    end
    finishCmd(p, msg.ok == true, msg.err)
end

local function onCmdRelay(msg)
    if msg.to ~= S.myId then return end
    local target, id = tonumber(msg.target), msg.id
    if not target or type(id) ~= "string" then return end
    if not CMDS[msg.cmd] then
        send("ack", msg.from, { id = id, ok = false, err = "unknown cmd", target = target })
        return
    end
    local p = S.pending[id]
    if p then
        p.origin = msg.from
        if p.queued then send("ack", msg.from, { id = id, queued = true, target = p.target }) end
        return
    end
    local d = S.done[id]
    if d then
        send("ack", msg.from, { id = id, ok = d.ok, err = d.err, target = d.target })
        return
    end
    M.issueCmd(target, msg.cmd, type(msg.params) == "table" and msg.params or {}, msg.from, id)
end

-- ---------------------------------------------------------------------------
-- Home records (server only)
-- ---------------------------------------------------------------------------
local function onHomeSave(msg)
    if type(msg.home) ~= "table" then return end
    local r = getRec(msg.from, false)
    S.homes[msg.from] = { home = msg.home, homeFacing = msg.homeFacing, gps = msg.gps == true,
        label = r and r.st.label, at = now() }
    saveHomes()
    local h = msg.home
    logLine("HOME #" .. msg.from .. " saved " .. tostring(h.x) .. "," .. tostring(h.y) .. "," .. tostring(h.z))
end

local function onHomeClear(msg)
    if S.homes[msg.from] == nil then return end
    S.homes[msg.from] = nil
    saveHomes()
    logLine("HOME #" .. msg.from .. " cleared (reinstalled)")
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
function M.handleMessage(sender, msg, protocol)
    if protocol ~= PROTO or type(msg) ~= "table" then return end
    if msg.v ~= 1 or type(msg.kind) ~= "string" or type(msg.from) ~= "number"
        or type(msg.boot) ~= "number" or type(msg.seq) ~= "number" then return end
    local hops = tonumber(msg.hops) or 0
    if hops > MAX_HOPS or msg.from == S.myId then return end
    if not markSeen(msg.from .. ":" .. msg.boot .. ":" .. msg.seq) then return end

    -- Relay (hub). A copy from an ender modem was heard by every wireless modem already.
    if S.mode == "server" and msg.kind ~= "fleet" and hops < MAX_HOPS and S.netOk
        and not (msg.mk == "ender" and not S.hasWired) then
        local c = copy(msg)
        c.hops = hops + 1
        c.hop, c.via, c.mk = 0, nil, S.modemKind
        pcall(rednet.broadcast, c, PROTO)
    end

    local k = msg.kind
    -- Any message from a turtle: it is reachable now, deliver its queued commands.
    if S.mode == "server" and TURTLE_KINDS[k] then
        local r = getRec(msg.from, false)
        if r then
            r.lastSeen = now()
            deliverQueued(r)
        end
    end
    if k == "status" then onStatus(msg)
    elseif k == "away" then onAway(msg)
    elseif k == "catchup" then onCatchup(msg)
    elseif k == "hello" then onHello(msg)
    elseif k == "event" then onEvent(msg)
    elseif k == "ack" then
        local r = getRec(msg.from, false)
        if r then r.lastSeen = now() end
        onAck(msg)
    elseif S.mode == "server" and k == "home_save" then onHomeSave(msg)
    elseif S.mode == "server" and k == "home_get" then onHomeGet(msg)
    elseif S.mode == "server" and k == "home_clear" then onHomeClear(msg)
    elseif S.mode == "server" and k == "cmd_relay" then onCmdRelay(msg)
    elseif S.mode == "pocket" and k == "fleet" then onFleet(msg)
    else
        local r = getRec(msg.from, false)
        if r then r.lastSeen = now() end
    end
    markDirty()
end

local function sendFleet(t)
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

function M.tick()
    local t = now()
    local list = {}
    for _, p in pairs(S.pending) do list[#list + 1] = p end
    for _, p in ipairs(list) do
        if t - (p.created or t) > QUEUE_EXPIRE_MS then
            finishCmd(p, false, "expired")
        elseif not p.queued and t >= p.deadline then
            local maxTries = (S.mode == "server") and (1 + ACK_RETRIES) or (1 + RELAY_RETRIES)
            if p.tries < maxTries then
                p.tries = p.tries + 1
                transmitCmd(p)
                local r = getRec(p.target, true)
                if r.cmd then r.cmd.tries = p.tries end
                markDirty()
            elseif S.mode == "server" then
                queueCmd(p)          -- no ack: keep it until the turtle is heard again
            else
                finishCmd(p, false, "no reply from server")
            end
        end
    end
    for id, d in pairs(S.done) do
        if t - d.at > DONE_KEEP_MS then S.done[id] = nil end
    end
    updateAlerts(t)
    if S.mode == "server" and t - S.lastFleet >= FLEET_EVERY_MS then sendFleet(t) end
    if t - S.lastDirtyTick >= 1000 then S.lastDirtyTick = t; markDirty() end
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------
local function ago(ms)
    if not ms or ms <= 0 then return "never" end
    local s = math.floor((now() - ms) / 1000)
    if s < 0 then s = 0 end
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    return math.floor(s / 3600) .. "h"
end

local function compact(n)
    n = math.floor(n)
    if n >= 100000 then return math.floor(n / 1000) .. "k" end
    if n >= 10000 then return math.floor(n / 100) / 10 .. "k" end
    return tostring(n)
end

-- returns text, isLow
local function fuelStr(st, withNeed)
    local f = st.fuel
    if f == nil then return "-", false end
    if type(f) ~= "number" then return "unl", false end
    local need = tonumber(st.fuelNeeded)
    local low = need ~= nil and f < need
    local s = compact(f)
    if withNeed and need then s = s .. "/" .. compact(need) end
    return s, low
end

local function posStr(p)
    if type(p) ~= "table" then return "-" end
    return tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z)
end

local function distHome(st)
    local p, h = st.pos, st.home
    if type(p) ~= "table" or type(h) ~= "table" then return nil end
    local ok, d = pcall(function() return math.abs(p.x - h.x) + math.abs(p.y - h.y) + math.abs(p.z - h.z) end)
    return ok and math.floor(d) or nil
end

local function phaseColor(ph)
    if ph == "MINING" or ph == "VEIN" then return colors.lime end
    if ph == "TO_WORK" or ph == "RETURNING" or ph == "UNLOADING" or ph == "REFUELING" then return colors.lightBlue end
    if ph == "PAUSED" or ph == "BOOT" or ph == "RECOVER" then return colors.yellow end
    if ph == "NEEDS_HELP" then return colors.orange end
    if ph == "ERROR" then return colors.red end
    if ph == "SILENT" or ph == "AWAY" then return colors.gray end
    if ph == "OVERDUE" then return colors.red end
    return colors.white
end

local function shownPhase(r)
    if r.alert == "SILENT" or r.alert == "OVERDUE" then return r.alert end
    if isAway(r, now()) then return "AWAY" end
    return r.st.phase or "?"
end

-- Reason line: while away and silent, when it is expected back.
local function reasonOf(r)
    if r.away and (isAway(r, now()) or r.alert == "OVERDUE") then
        return awayText(r) .. (r.alert == "OVERDUE" and " - OVERDUE" or "")
    end
    return r.st.reason
end
M.shownPhase, M.reasonOf = shownPhase, reasonOf

local function cmdLine(r)
    local c = r.cmd
    if not c then return nil end
    if c.state == "pending" then
        return c.name .. ": waiting (" .. tostring(c.tries or 1) .. ")", colors.yellow
    elseif c.state == "queued" then
        return c.name .. ": queued " .. ago(c.at), colors.yellow
    elseif c.state == "ok" then
        return c.name .. ": ok " .. ago(c.at), colors.lime
    end
    return c.name .. ": FAILED " .. tostring(c.err or ""), colors.red
end

local function sortedTurtles()
    local arr = {}
    for _, r in pairs(S.turtles) do arr[#arr + 1] = r end
    table.sort(arr, function(a, b)
        local aa, ba = a.alert and 0 or 1, b.alert and 0 or 1
        if aa ~= ba then return aa < ba end
        local la, lb = labelOf(a):lower(), labelOf(b):lower()
        if la ~= lb then return la < lb end
        return a.id < b.id
    end)
    return arr
end

-- ---------------------------------------------------------------------------
-- UI: one responsive renderer, any number of displays (monitor + terminal)
-- ---------------------------------------------------------------------------
function M.newUI(dev, side)
    local ui = { dev = dev, side = side, view = "list", page = 1, sel = nil, buttons = {},
        input = "", msg = nil, text = nil, w = 1, h = 1 }
    ui.color = dev.isColor and dev.isColor() or false
    return ui
end

local function mapColor(ui, c, isBg)
    if ui.color then return c end
    if isBg then return (c == colors.black) and colors.black or colors.gray end
    return (c == colors.gray or c == colors.lightGray) and c or colors.white
end

local function put(ui, x, y, text, fg, bg)
    if y < 1 or y > ui.h or x > ui.w then return end
    text = tostring(text)
    if x < 1 then text = text:sub(2 - x); x = 1 end
    if #text > ui.w - x + 1 then text = text:sub(1, ui.w - x + 1) end
    if #text == 0 then return end
    local d = ui.out
    d.setTextColor(mapColor(ui, fg or colors.white, false))
    d.setBackgroundColor(mapColor(ui, bg or colors.black, true))
    d.setCursorPos(x, y)
    d.write(text)
end

local function fillLine(ui, y, bg)
    put(ui, 1, y, string.rep(" ", ui.w), colors.white, bg)
end

local function button(ui, x, y, w, label, bg, fn, fg)
    if w < 1 or y < 1 or y > ui.h then return end
    local t = trunc(label, w)
    local left = math.floor((w - #t) / 2)
    put(ui, x, y, string.rep(" ", left) .. t .. string.rep(" ", w - left - #t), fg or colors.white, bg)
    ui.buttons[#ui.buttons + 1] = { x1 = x, y1 = y, x2 = x + w - 1, y2 = y, fn = fn }
end

local function zone(ui, x1, y1, x2, y2, fn)
    ui.buttons[#ui.buttons + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn }
end

local function header(ui, title, right, backable)
    fillLine(ui, 1, colors.blue)
    local x = 1
    if backable then
        button(ui, 1, 1, 3, "<", colors.gray, function() ui.view = (ui.view == "detail") and "list" or "detail" end)
        x = 5
    end
    right = right or ""
    local room = ui.w - x + 1 - (#right > 0 and (#right + 1) or 0)
    if room < 1 then right = ""; room = ui.w - x + 1 end
    put(ui, x, 1, trunc(title, room), colors.white, colors.blue)
    if #right > 0 then put(ui, ui.w - #right + 1, 1, right, colors.yellow, colors.blue) end
end

local function gridCols(ui, maxCols)
    return math.max(1, math.min(maxCols, math.floor((ui.w + 1) / 12)))
end

-- Lay buttons out in a grid at the bottom. defs = {{label, bg, fn, fg}, ...}.
-- reserve = rows wanted above the grid (besides the header). Returns top row used.
local function buttonGrid(ui, defs, maxCols, reserve)
    local bottom = ui.h
    local cols = gridCols(ui, maxCols)
    if ui.h > 1 then cols = math.min(#defs, math.max(cols, math.ceil(#defs / (ui.h - 1)))) end
    local rows = math.ceil(#defs / cols)
    local bw = math.max(1, math.floor((ui.w - (cols + 1)) / cols))
    if ui.w < cols + 2 then bw = math.max(1, math.floor(ui.w / cols)) end
    local gap = (bottom - 1 - (reserve or 0) >= rows * 2 - 1) and 1 or 0
    local top = bottom - (rows * (1 + gap) - gap) + 1
    for i, d in ipairs(defs) do
        local c = (i - 1) % cols
        local rr = math.floor((i - 1) / cols)
        local x = 2 + c * (bw + 1)
        if ui.w < cols + 2 then x = 1 + c * bw end
        button(ui, x, top + rr * (1 + gap), bw, d[1], d[2], d[3], d[4])
    end
    return top
end

local function currentRec(ui)
    return ui.sel and S.turtles[ui.sel] or nil
end

local function doCmd(ui, cmd, params)
    if ui.sel then M.issueCmd(ui.sel, cmd, params) end
    ui.view = "detail"
end

-- List view ---------------------------------------------------------------
local function drawRow(ui, r, y, rowsPer)
    local w, st = ui.w, r.st
    local bg = r.alert and colors.red or colors.black
    for k = 0, rowsPer - 1 do fillLine(ui, y + k, bg) end
    local ph = shownPhase(r)
    local phFg = r.alert and colors.yellow or phaseColor(ph)
    local function lowFg(low) return low and (r.alert and colors.yellow or colors.red) or colors.white end
    if w >= 40 then
        local wide = w >= 60
        local nw, pw, fw = wide and 16 or 13, wide and 11 or 7, wide and 12 or 6
        local fuel, low = fuelStr(st, wide)
        local d = distHome(st)
        local x = 1
        put(ui, x, y, pad(labelOf(r), nw), colors.white, bg); x = x + nw + 1
        put(ui, x, y, pad(wide and ph or (PHASE_SHORT[ph] or ph), pw), phFg, bg); x = x + pw + 1
        put(ui, x, y, pad(fuel, fw), lowFg(low), bg); x = x + fw + 1
        put(ui, x, y, pad(d and ("h" .. d) or "h-", 6), colors.white, bg); x = x + 7
        put(ui, x, y, pad(ago(r.lastSeen), 5), colors.lightGray, bg); x = x + 6
        if rowsPer == 1 and x <= w then
            put(ui, x, y, trunc(reasonOf(r) or "", w - x + 1), colors.lightGray, bg)
        end
    else
        local fuel, low = fuelStr(st, false)
        local pw, fw = 6, 5
        local nw = w - pw - fw - 2
        if nw < 3 then fw = 0; nw = w - pw - 1 end
        put(ui, 1, y, pad(labelOf(r), nw), colors.white, bg)
        put(ui, nw + 2, y, pad(PHASE_SHORT[ph] or ph, pw), phFg, bg)
        if fw > 0 then put(ui, w - fw + 1, y, lpad(fuel, fw), lowFg(low), bg) end
    end
    if rowsPer == 2 then
        local t, fg = reasonOf(r) or st.lastError, colors.lightGray
        if not t then t, fg = cmdLine(r) end
        if not t then t = "#" .. r.id .. " " .. posStr(st.pos) end
        put(ui, 3, y + 1, trunc(t, w - 2), r.alert and colors.white or (fg or colors.lightGray), bg)
    end
    zone(ui, 1, y, w, y + rowsPer - 1, function() ui.sel = r.id; ui.view = "detail" end)
end

local function renderList(ui)
    local w, h = ui.w, ui.h
    local arr = sortedTurtles()
    local nAlert = 0
    for _, r in ipairs(arr) do if r.alert then nAlert = nAlert + 1 end end
    local title = S.mode == "server" and ("TMINER srv#" .. S.myId) or "TMINER pocket"
    header(ui, title, #arr .. (nAlert > 0 and (" " .. nAlert .. "!") or ""), false)
    local bodyTop, bodyBot = 2, h - 1
    local bodyH = bodyBot - bodyTop + 1
    if bodyH < 1 then return end
    local rowsPer = (w >= 30 and bodyH >= #arr * 2) and 2 or 1
    local perPage = math.max(1, math.floor(bodyH / rowsPer))
    local pages = math.max(1, math.ceil(#arr / perPage))
    if ui.page > pages then ui.page = pages end
    if ui.page < 1 then ui.page = 1 end
    if #arr == 0 then
        put(ui, 1, 2, trunc(S.mode == "pocket" and "Waiting for server..." or "No turtles heard yet", w), colors.lightGray)
    end
    for i = 1, perPage do
        local r = arr[(ui.page - 1) * perPage + i]
        if not r then break end
        drawRow(ui, r, bodyTop + (i - 1) * rowsPer, rowsPer)
    end
    -- footer
    fillLine(ui, h, colors.gray)
    local x = 1
    if pages > 1 then
        button(ui, 1, h, 3, "<", colors.blue, function() ui.page = math.max(1, ui.page - 1) end)
        button(ui, 5, h, 3, ">", colors.blue, function() ui.page = math.min(pages, ui.page + 1) end)
        x = 9
    end
    local info
    if S.mode == "pocket" then
        if S.fleetFrom and now() - S.fleetAt < 15000 then
            info = "srv#" .. S.fleetFrom .. " " .. ago(S.fleetAt)
        else
            info = "no server"
        end
    else
        info = S.netOk and ("relay on " .. S.modemKind) or "NO MODEM"
    end
    if pages > 1 then info = ui.page .. "/" .. pages .. " " .. info end
    local logW = (w - x + 1 >= 10) and 5 or 0
    put(ui, x, h, trunc(info, w - x + 1 - (logW > 0 and logW + 1 or 0)), colors.white, colors.gray)
    if logW > 0 then button(ui, w - logW + 1, h, logW, "LOG", colors.blue, function() ui.view = "log" end) end
end

-- Detail view ---------------------------------------------------------------
local function detailLines(r, wide)
    local st, L = r.st, {}
    local function add(k, v, fg) L[#L + 1] = { k, tostring(v), fg } end
    local ph = shownPhase(r)
    add("Phase", ph .. (r.alert and r.alert ~= ph and (" " .. r.alert) or ""), phaseColor(ph))
    local why = reasonOf(r)
    add("Why", why or "-", why and colors.orange or nil)
    local need = tonumber(st.fuelNeeded)
    local fuelTxt, low = fuelStr(st, false)
    add("Fuel", fuelTxt .. (need and (" need " .. compact(need)) or ""), low and colors.red or nil)
    local d = distHome(st)
    add("Home", (d and (d .. " blk") or "-") .. (wide and type(st.home) == "table" and (" @" .. posStr(st.home)) or ""))
    add("Pos", posStr(st.pos) .. (st.facing and (" f" .. tostring(st.facing)) or ""))
    local j = st.job
    if type(j) == "table" then
        add("Job", "c" .. tostring(j.corridor) .. " b" .. tostring(j.branch) .. " " .. tostring(j.side or "")
            .. " s" .. tostring(j.step))
    else
        add("Job", "-")
    end
    local s = type(st.stats) == "table" and st.stats or {}
    add("Ores", tostring(s.ores or "-") .. (wide and ("  blocks " .. tostring(s.blocks or "-") .. "  trips "
        .. tostring(s.trips or "-")) or (" trips " .. tostring(s.trips or "-"))))
    add("Seen", ago(r.lastSeen) .. " ago", r.alert == "SILENT" and colors.red or nil)
    add("GPS", (st.gps == true and "yes" or (st.gps == false and "no" or "-")) .. "  v" .. tostring(st.version or "?"))
    local cfg = type(st.cfg) == "table" and st.cfg or {}
    add("Cfg", "Y " .. tostring(cfg.targetY or "-") .. " focus " .. tostring(cfg.focus or "-"))
    add("Error", st.lastError or "-", st.lastError and colors.red or nil)
    local ct, cfg2 = cmdLine(r)
    add("Cmd", ct or "-", cfg2)
    for _, e in ipairs(r.events) do
        add("Ev", ago(e.at) .. " " .. tostring(e.text),
            e.level == "error" and colors.red or (e.level == "warn" and colors.orange or colors.lightGray))
    end
    return L
end

local function keyDef(key)
    for _, d in ipairs(SET_KEYS) do if d[1] == key then return d end end
    return nil
end

-- Open the value screen for one SET key.
local function editKey(ui, r, key)
    local d = keyDef(key)
    if not d then return end
    ui.setKey, ui.msg = key, nil
    if d[3] == "string" then
        ui.view = "focus"
    elseif d[3] == "bool" then
        ui.view = "bool"
    else
        local c = key == "TARGET_Y" and type(r.st.cfg) == "table" and r.st.cfg.targetY
        ui.input = c and tostring(c) or ""
        ui.view = "num"
    end
end

local CONFIRM = {
    RESET_HOME = { "Reset home?", "YES RESET", function(r)
        return "Set the home of " .. nameOf(r) .. " to where it is NOW (" .. posStr(r.st.pos)
            .. ")? Only do this when it sits at its home chest."
    end },
    RESET_JOB = { "Reset job?", "YES RESET", function(r)
        return "Restart the mining grid of " .. nameOf(r) .. " at corridor 0 next time it is home?"
            .. " Already mined tunnels are walked again. Send RESUME if it is DONE or IDLE."
    end },
    REBOOT = { "Reboot?", "YES REBOOT", function(r)
        return "Reboot " .. nameOf(r) .. "? It saves first and carries on after the restart."
    end },
}

local function confirm(ui, cmd)
    ui.confirmCmd = cmd
    ui.view = "confirm"
end

local function cmdDefs(ui, r)
    return {
        { "RETURN HOME", colors.orange, function() doCmd(ui, "RETURN_HOME") end },
        { "PAUSE", colors.yellow, function() doCmd(ui, "PAUSE") end, colors.black },
        { "RESUME", colors.green, function() doCmd(ui, "RESUME") end },
        { "STATUS", colors.blue, function() doCmd(ui, "REQUEST_STATUS") end },
        { "TARGET Y", colors.blue, function() editKey(ui, r, "TARGET_Y") end },
        { "FOCUS ORE", colors.blue, function() editKey(ui, r, "FOCUS") end },
        { "SET...", colors.blue, function() ui.view = "keys" end },
        { "UPDATE", colors.purple, function() doCmd(ui, "UPDATE") end },
        { "RESET JOB", colors.red, function() confirm(ui, "RESET_JOB") end },
        { "RESET HOME", colors.red, function() confirm(ui, "RESET_HOME") end },
        { "REBOOT", colors.red, function() confirm(ui, "REBOOT") end },
        { "BACK", colors.gray, function() ui.view = "list" end },
    }
end

local CORE_LINES = 12

local function renderDetail(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    header(ui, labelOf(r) .. " #" .. r.id, nil, true)
    local defs = cmdDefs(ui, r)
    local lines = detailLines(r, ui.w >= 40)
    local gridRows = math.ceil(#defs / gridCols(ui, 3))
    local lastInfo
    if ui.h - 2 - gridRows < math.min(CORE_LINES, 6) then
        -- small screen: info on this page, commands on their own page
        local half = math.max(1, math.floor((ui.w - 3) / 2))
        button(ui, 2, ui.h, half, "BACK", colors.gray, function() ui.view = "list" end)
        button(ui, 3 + half, ui.h, half, "CMDS", colors.blue, function() ui.view = "cmds" end)
        lastInfo = ui.h - 1
    else
        local top = buttonGrid(ui, defs, 3, #lines + 1)
        lastInfo = top - 2
        if lastInfo < 2 then lastInfo = top - 1 end
    end
    local kw = 7
    for i, l in ipairs(lines) do
        local y = 1 + i
        if y > lastInfo then break end
        put(ui, 1, y, pad(l[1], kw - 1), colors.lightGray)
        put(ui, kw, y, trunc(l[2], ui.w - kw + 1), l[3] or colors.white)
        local full = l[1] .. ": " .. l[2]
        zone(ui, 1, y, ui.w, y, function() ui.text = full; ui.view = "text" end)
    end
end

local function renderCmds(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    header(ui, "Cmd " .. labelOf(r) .. " #" .. r.id, nil, true)
    local defs = cmdDefs(ui, r)
    defs[#defs][3] = function() ui.view = "detail" end
    buttonGrid(ui, defs, 3)
end

-- Key picker (SET any remote key) -------------------------------------------
local function renderKeys(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    header(ui, "Set #" .. r.id, nil, true)
    local defs = {}
    for _, d in ipairs(SET_KEYS) do
        local key = d[1]
        defs[#defs + 1] = { d[2], colors.blue, function() editKey(ui, r, key) end }
    end
    defs[#defs + 1] = { "CANCEL", colors.red, function() ui.view = "detail" end }
    buttonGrid(ui, defs, 4)
end

-- Boolean entry ---------------------------------------------------------------
local function renderBool(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    local d = keyDef(ui.setKey)
    if not d or d[3] ~= "bool" then d = keyDef("VEIN_MINING") end
    header(ui, d[2] .. " #" .. r.id, nil, true)
    put(ui, 1, 2, trunc("Set " .. d[1] .. " to:", ui.w), colors.lightGray)
    buttonGrid(ui, {
        { "TRUE", colors.green, function() doCmd(ui, "SET", { key = d[1], value = true }) end },
        { "FALSE", colors.orange, function() doCmd(ui, "SET", { key = d[1], value = false }) end },
        { "CANCEL", colors.red, function() ui.view = "detail" end },
    }, 3, 1)
end

-- Numeric entry (any number key) ----------------------------------------------
local function numKeyDef(ui)
    local d = keyDef(ui.setKey)
    if not d or d[3] ~= "number" then d = keyDef("TARGET_Y") end
    return d
end

local function numOk(ui)
    local d = numKeyDef(ui)
    local v = tonumber(ui.input)
    if not v or v ~= math.floor(v) or v < d[4] or v > d[5] then
        ui.msg = "Need integer " .. d[4] .. ".." .. d[5]
        return
    end
    doCmd(ui, "SET", { key = d[1], value = v })
end

local function numKey(ui, ch)
    local d = numKeyDef(ui)
    local maxLen = math.max(#tostring(d[4]), #tostring(d[5]))
    if ch == "DEL" then ui.input = ui.input:sub(1, -2)
    elseif ch == "-" then
        if d[4] < 0 then
            if ui.input:sub(1, 1) == "-" then ui.input = ui.input:sub(2) else ui.input = "-" .. ui.input end
        end
    elseif #ui.input:gsub("^%-", "") < maxLen then ui.input = ui.input .. ch end
    ui.msg = nil
end

local function renderNum(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    local d = numKeyDef(ui)
    header(ui, d[2] .. " #" .. r.id, nil, true)
    local lbl = d[2] .. " = "
    if #lbl > math.floor(ui.w / 2) then lbl = "= " end
    put(ui, 1, 2, lbl, colors.lightGray)
    put(ui, #lbl + 1, 2, ui.input .. "_", colors.yellow)
    if ui.msg then put(ui, 1, 3, trunc(ui.msg, ui.w), colors.red)
    else put(ui, 1, 3, trunc("range " .. d[4] .. ".." .. d[5], ui.w), colors.gray) end
    local defs = {}
    for _, k in ipairs({ "7", "8", "9", "DEL", "4", "5", "6", "-", "1", "2", "3", "0" }) do
        defs[#defs + 1] = { k, colors.gray, function() numKey(ui, k) end }
    end
    defs[#defs + 1] = { "CANCEL", colors.red, function() ui.view = "detail" end }
    defs[#defs + 1] = { "", colors.black, function() end }
    defs[#defs + 1] = { "", colors.black, function() end }
    defs[#defs + 1] = { "OK", colors.green, function() numOk(ui) end }
    -- 4 columns regardless of width (keys are short)
    local cols, rows = 4, 4
    local bw = math.max(1, math.floor((ui.w - 5) / 4))
    local gap = (ui.h - 4 >= rows * 2) and 1 or 0
    local top = math.max(4, ui.h - (rows * (1 + gap) - gap) + 1)
    for i, d in ipairs(defs) do
        local c, rr = (i - 1) % cols, math.floor((i - 1) / cols)
        if d[1] ~= "" then button(ui, 2 + c * (bw + 1), top + rr * (1 + gap), bw, d[1], d[2], d[3]) end
    end
end

-- Focus ore picker ---------------------------------------------------------
local function renderFocus(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    header(ui, "Focus ore #" .. r.id, nil, true)
    local cur = type(r.st.cfg) == "table" and r.st.cfg.focus
    local defs = {}
    for _, f in ipairs(FOCUS_LIST) do
        defs[#defs + 1] = { f, f == cur and colors.green or colors.blue,
            function() doCmd(ui, "SET", { key = "FOCUS", value = f }) end }
    end
    defs[#defs + 1] = { "CANCEL", colors.red, function() ui.view = "detail" end }
    buttonGrid(ui, defs, 3)
end

-- Confirm RESET_HOME / RESET_JOB / REBOOT ------------------------------------
local function wrap(text, w)
    local out = {}
    if w < 1 then return out end
    for para in (tostring(text) .. "\n"):gmatch("(.-)\n") do
        while #para > w do
            local cut = para:sub(1, w):match("^.*() ") or (w + 1)
            if cut <= 1 then cut = w + 1 end
            out[#out + 1] = para:sub(1, cut - 1)
            para = para:sub(cut):gsub("^ ", "")
        end
        out[#out + 1] = para
    end
    return out
end

local function renderConfirm(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    local cmd = CONFIRM[ui.confirmCmd] and ui.confirmCmd or "RESET_HOME"
    local c = CONFIRM[cmd]
    header(ui, c[1], nil, true)
    local lines = wrap(c[3](r), ui.w)
    for i, l in ipairs(lines) do
        if 1 + i > ui.h - 2 then break end
        put(ui, 1, 1 + i, l, colors.white)
    end
    local half = math.max(1, math.floor((ui.w - 3) / 2))
    button(ui, 2, ui.h, half, c[2], colors.red, function() doCmd(ui, cmd, {}) end)
    button(ui, 3 + half, ui.h, half, "NO", colors.gray, function() ui.view = "detail" end)
end

-- Text view (full field / log) ----------------------------------------------
local function renderText(ui, title, lines, back)
    fillLine(ui, 1, colors.blue)
    button(ui, 1, 1, 3, "<", colors.gray, back)
    put(ui, 5, 1, trunc(title, ui.w - 4), colors.white, colors.blue)
    local avail = ui.h - 1
    local first = math.max(1, #lines - avail + 1)
    for i = first, #lines do
        put(ui, 1, 2 + i - first, trunc(lines[i], ui.w), colors.white)
    end
    zone(ui, 1, 2, ui.w, ui.h, back)
end

function M.render(ui)
    local w, h = ui.dev.getSize()
    ui.w, ui.h = w, h
    if window and not ui.win then ui.win = window.create(ui.dev, 1, 1, w, h, false) end
    if ui.win then
        local ww, wh = ui.win.getSize()
        if ww ~= w or wh ~= h then ui.win.reposition(1, 1, w, h) end
        ui.win.setVisible(false)
        ui.out = ui.win
    else
        ui.out = ui.dev
    end
    ui.buttons = {}
    ui.out.setBackgroundColor(colors.black)
    ui.out.clear()
    if ui.view == "detail" then renderDetail(ui)
    elseif ui.view == "cmds" then renderCmds(ui)
    elseif ui.view == "num" then renderNum(ui)
    elseif ui.view == "focus" then renderFocus(ui)
    elseif ui.view == "keys" then renderKeys(ui)
    elseif ui.view == "bool" then renderBool(ui)
    elseif ui.view == "confirm" then renderConfirm(ui)
    elseif ui.view == "text" then
        renderText(ui, "Detail", wrap(ui.text or "", w), function() ui.view = "detail" end)
    elseif ui.view == "log" then
        local lines = {}
        for _, l in ipairs(S.log) do for _, p in ipairs(wrap(l, w)) do lines[#lines + 1] = p end end
        renderText(ui, "Event log", lines, function() ui.view = "list" end)
    else
        ui.view = "list"
        renderList(ui)
    end
    -- Keyboard focus marker (after the first arrow/tab key; basic computers have no mouse).
    if ui.focus then
        if ui.focus > #ui.buttons then ui.focus = #ui.buttons end
        local b = ui.buttons[ui.focus]
        if b then put(ui, b.x1, b.y1, ">", colors.yellow, colors.black) end
    end
    if ui.win then ui.win.setVisible(true) end
end

-- Arrow keys / Tab move a focus over the clickable things, Enter activates it. Works on any
-- computer (no colour, mouse or touch needed). Returns true when the key was used.
function M.navKey(ui, key)
    if not keys then return false end
    local n = #ui.buttons
    if key == keys.down or key == keys.right or key == keys.tab then
        if n == 0 then return true end
        ui.focus = ((ui.focus or 0) % n) + 1
    elseif key == keys.up or key == keys.left then
        if n == 0 then return true end
        ui.focus = (((ui.focus or 1) - 2) % n) + 1
    elseif (key == keys.enter or key == keys.numPadEnter) and ui.focus and ui.buttons[ui.focus] then
        local b = ui.buttons[ui.focus]
        ui.focus = 1
        b.fn()
    else
        return false
    end
    M.render(ui)
    return true
end

function M.click(ui, x, y)
    for i = #ui.buttons, 1, -1 do
        local b = ui.buttons[i]
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
            b.fn()
            M.render(ui)
            return true
        end
    end
    return false
end

local function renderAll()
    S.dirtyQueued = false
    for _, ui in ipairs(S.uis) do pcall(M.render, ui) end
end

-- ---------------------------------------------------------------------------
-- Init and loops
-- ---------------------------------------------------------------------------
local function findMonitor(sideArg)
    if sideArg == "none" then return nil end
    if sideArg and sideArg ~= "auto" and peripheral.getType(sideArg) == "monitor" then
        return peripheral.wrap(sideArg), sideArg
    end
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "monitor" then return peripheral.wrap(n), n end
    end
    return nil
end

local function attachMonitor(cfg)
    local mon, side = findMonitor(cfg.monitor)
    if not mon then return end
    pcall(mon.setTextScale, cfg.scale)
    table.insert(S.uis, 1, M.newUI(mon, side))
end

function M.init(opts)
    opts = opts or {}
    S.mode = opts.mode or (pocket ~= nil and "pocket" or "server")
    S.myId = os.getComputerID()
    S.boot = now()
    S.cfg = { monitor = opts.monitor or "auto", scale = opts.scale or 0.5 }
    openModems()
    if S.mode == "server" then
        S.homes = loadHomes()
        loadLog()
        logLine("server #" .. S.myId .. " started" .. (S.netOk and "" or " (NO MODEM)"))
    else
        logLine("pocket #" .. S.myId .. " started")
    end
    S.uis = {}
    if not opts.noDisplay then
        if S.mode == "server" then attachMonitor(S.cfg) end
        S.uis[#S.uis + 1] = M.newUI(term.current(), nil)
    end
end

local function netLoop()
    while true do
        local ev = { os.pullEvent() }
        if ev[1] == "rednet_message" then
            M.handleMessage(ev[2], ev[3], ev[4])
        elseif ev[1] == "modem_message" and not S.inferredEnder then
            -- A basic-modem sender heard from beyond any basic range: ours is an ender modem.
            local p, d = ev[5], ev[6]
            if type(p) == "table" and p.sProtocol == PROTO and type(p.message) == "table"
                and p.message.mk == "basic" and type(d) == "number" and d > 400 then
                S.inferredEnder = true
                openModems()
                markDirty()
            end
        end
    end
end

local function tickLoop()
    local timer = os.startTimer(TICK)
    while true do
        local _, id = os.pullEvent("timer")
        if id == timer then
            M.tick()
            timer = os.startTimer(TICK)
        end
    end
end

local function uiLoop()
    renderAll()
    while true do
        local ev = { os.pullEvent() }
        local e = ev[1]
        if e == "tminer_redraw" then
            renderAll()
        elseif e == "monitor_touch" or e == "mouse_click" then
            for _, ui in ipairs(S.uis) do
                if (e == "monitor_touch" and ui.side == ev[2]) or (e == "mouse_click" and ui.side == nil) then
                    M.click(ui, ev[3], ev[4])
                end
            end
        elseif e == "char" or e == "key" then
            for _, ui in ipairs(S.uis) do
                if ui.side == nil and e == "key" and M.navKey(ui, ev[2]) then
                    -- handled: keyboard navigation (basic computers have no mouse)
                elseif ui.side == nil and ui.view == "num" then
                    if e == "char" and ev[2]:match("^[0-9%-]$") then numKey(ui, ev[2])
                    elseif e == "key" and ev[2] == keys.backspace then numKey(ui, "DEL")
                    elseif e == "key" and (ev[2] == keys.enter or ev[2] == keys.numPadEnter) then numOk(ui) end
                    M.render(ui)
                end
            end
        elseif e == "monitor_resize" or e == "term_resize" then
            renderAll()
        elseif e == "peripheral" then
            if peripheral.getType(ev[2]) == "modem" then openModems() end
            if peripheral.getType(ev[2]) == "monitor" and S.mode == "server"
                and not (S.uis[1] and S.uis[1].side) then
                attachMonitor(S.cfg)
            end
            renderAll()
        elseif e == "peripheral_detach" then
            for i = #S.uis, 1, -1 do
                if S.uis[i].side == ev[2] then table.remove(S.uis, i) end
            end
            openModems()
            renderAll()
        end
    end
end

function M.run()
    parallel.waitForAny(netLoop, tickLoop, uiLoop)
end

local args = { ... }
if args[1] == "--lib" then return M end
M.init({ monitor = args[1], scale = tonumber(args[2]) })
M.run()
