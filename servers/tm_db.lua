-- Version: 1.0.2
-- TurtleMiner server, database part: shared state, files, event log, turtle records, the
-- command queue (store-and-forward) and the replication format (snapshot / delta).
-- Loaded by tminer_server.lua (or central_monitor.lua) into the shared table T:
--   loadfile("tm_db.lua", nil, _ENV)(T)
-- The leader owns the database (homes, queued commands, away/ETAs, event log); replicas get
-- a copy from tm_cluster.lua. Only the leader changes it; replicas forward their changes.
local T = ...

-- Store-and-forward / expected absence (docs/COMMS.md rules 2 and 3)
local QUEUE_EXPIRE_MS  = 24 * 3600 * 1000   -- queued commands are dropped after this
local HEARD_MS         = 30000              -- heard within this: send commands at once
local OVERDUE_FACTOR   = 1.5                -- alert when away longer than ETA * factor + grace
local OVERDUE_GRACE_MS = 120000

local SILENT_MS        = 60000
local ACK_TIMEOUT_MS   = 3000
local ACK_RETRIES      = 3       -- server: 1 send + 3 retries
local RELAY_TIMEOUT_MS = 15000   -- pocket: server needs up to 12 s before it reports a failure
local RELAY_RETRIES    = 1
local DONE_KEEP_MS     = 60000
local HOME_FILE        = "miner_homes.db"
local LOG_FILE         = "miner_events.log"
local DB_FILE          = "tminer_db.dat"
local LOG_MAX          = 500
local LOG_KEEP         = 400
local EVENTS_KEEP      = 5
local DEDUPE_MAX       = 256

T.QUEUE_EXPIRE_MS, T.HEARD_MS, T.SILENT_MS, T.DONE_KEEP_MS = QUEUE_EXPIRE_MS, HEARD_MS, SILENT_MS, DONE_KEEP_MS
T.DEDUPE_MAX = DEDUPE_MAX

T.CMDS = {
    RETURN_HOME = true, PAUSE = true, RESUME = true, SET = true, REQUEST_STATUS = true,
    RESET_JOB = true, RESET_HOME = true, UPDATE = true, REBOOT = true, ARMY_JOIN = true, ARMY_LEAVE = true,
}
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
    modemKind = "none", hasWired = false, hasWireless = false, inferredEnder = false,
    evSeen = {}, evSeenQ = {}, evSeenPos = 0,
    -- replication (leader: what changed since the last delta; all: version of the data)
    epoch = 0, dbSeq = 0, dT = {}, dH = {}, dP = {}, logOut = {},
}
T.S = S

local function now() return os.epoch("utc") end
T.now = now

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end
T.copy = copy

local function trunc(s, n)
    s = tostring(s or "")
    if n < 1 then return "" end
    if #s > n then return s:sub(1, n) end
    return s
end
T.trunc = trunc
function T.pad(s, n) s = trunc(s, n); return s .. string.rep(" ", n - #s) end
function T.lpad(s, n) s = trunc(s, n); return string.rep(" ", n - #s) .. s end

function T.markDirty()
    if not S.dirtyQueued then
        S.dirtyQueued = true
        if os.queueEvent then os.queueEvent("tminer_redraw") end
    end
end
local markDirty = T.markDirty

-- Leader-owned data may only change on the leader (or a pocket's own view).
local function owner() return S.mode == "pocket" or T.isLeader() end
function T.isLeader() return S.mode == "server" and T.C ~= nil and T.C.role == "leader" end

-- ---------------------------------------------------------------------------
-- Files (atomic write: tmp + move)
-- ---------------------------------------------------------------------------
local function writeAtomic(path, text)
    local tmp = path .. ".tmp"
    -- A full disk makes write() throw ("Out of space"): keep the old file and carry on.
    local ok = pcall(function()
        local h = fs.open(tmp, "w")
        if not h then error("open failed") end
        local wok, werr = pcall(h.write, text)
        h.close()
        if not wok then error(werr) end
        if fs.exists(path) then fs.delete(path) end
        fs.move(tmp, path)
    end)
    if not ok then
        pcall(fs.delete, tmp)
        if not T.diskFullWarned then
            T.diskFullWarned = true
            pcall(function() T.logLine("DISK: cannot write " .. path .. " (out of space?). Free space on this computer.") end)
        end
        return false
    end
    T.diskFullWarned = nil
    return true
end
T.writeAtomic = writeAtomic

local function readFile(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local s = h.readAll()
    h.close()
    return s
end
T.readFile = readFile

local function loadTable(path)
    for _, p in ipairs({ path, path .. ".tmp" }) do
        local s = readFile(p)
        local t = s and textutils.unserialize(s)
        if type(t) == "table" then return t end
    end
    return nil
end

function T.saveHomes()
    pcall(writeAtomic, HOME_FILE, textutils.serialize(S.homes))
end

-- Version of the data + the command queue survive a reboot (cold restart of the cluster).
local function packCmd(p)
    if not p then return nil end
    return { id = p.id, target = p.target, cmd = p.cmd, params = p.params, created = p.created,
        queuedAt = p.queuedAt, queued = p.queued, origin = p.origin, forwarded = p.forwarded }
end
T.packCmd = packCmd

function T.saveDb()
    if S.mode ~= "server" then return end
    local pend = {}
    for id, p in pairs(S.pending) do if not p.forwarded then pend[id] = packCmd(p) end end
    pcall(writeAtomic, DB_FILE, textutils.serialize({ epoch = S.epoch, seq = S.dbSeq, pending = pend }))
end

function T.loadDb()
    S.homes = loadTable(HOME_FILE) or {}
    if T.army then T.army.load() end
    local d = loadTable(DB_FILE)
    if d then
        S.epoch, S.dbSeq = tonumber(d.epoch) or 0, tonumber(d.seq) or 0
        if type(d.pending) == "table" then
            for id, p in pairs(d.pending) do
                if type(p) == "table" and p.target then
                    p.queued, p.tries, p.deadline = true, 1, math.huge
                    S.pending[id] = p
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Event log (server: file, rotating; pocket: memory only)
-- ---------------------------------------------------------------------------
local function stamp(ms)
    local ok, s = pcall(os.date, "!%m-%d %H:%M:%S", math.floor(ms / 1000))
    return ok and s or tostring(math.floor(ms / 1000))
end

function T.loadLog()
    local s = readFile(LOG_FILE)
    if not s then return end
    for line in s:gmatch("[^\n]+") do S.log[#S.log + 1] = line end
    while #S.log > LOG_MAX do table.remove(S.log, 1) end
end

local function rewriteLog()
    if S.mode == "server" then pcall(writeAtomic, LOG_FILE, table.concat(S.log, "\n") .. "\n") end
end
T.rewriteLog = rewriteLog

local function appendLine(line)
    S.log[#S.log + 1] = line
    if #S.log > LOG_MAX then
        local keep = {}
        for i = #S.log - LOG_KEEP + 1, #S.log do keep[#keep + 1] = S.log[i] end
        S.log = keep
        rewriteLog()
    elseif S.mode == "server" then
        pcall(function()
            local h = fs.open(LOG_FILE, "a")
            if h then h.write(line .. "\n"); h.close() end
        end)
    end
    markDirty()
end

function T.logLine(text)
    local ms = now()
    appendLine(stamp(ms) .. " " .. text)
    if T.isLeader() then S.logOut[#S.logOut + 1] = { ms = ms, text = text } end
end

-- Insert lines with their original times: sorted insert, then one file rewrite.
local function logInsert(entries)
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
    rewriteLog()
    markDirty()
end
T.logInsert = logInsert

-- Merge catch-up lines (leader): logged here and replicated.
function T.logMerge(entries)
    if #entries == 0 then return end
    logInsert(entries)
    if T.isLeader() then
        for _, e in ipairs(entries) do S.logOut[#S.logOut + 1] = { ms = e.ms, text = e.text } end
    end
end

-- Clock text for an epoch-ms time, in the server's local time when os.epoch("local") exists.
function T.clockText(ms)
    local off = 0
    local okL, l = pcall(os.epoch, "local")
    local okU, u = pcall(os.epoch, "utc")
    if okL and okU and type(l) == "number" and type(u) == "number" then
        off = math.floor((l - u) / 60000 + 0.5) * 60000
    end
    local ok, s = pcall(os.date, "!%H:%M", math.floor((ms + off) / 1000))
    return ok and s or "?"
end

-- ---------------------------------------------------------------------------
-- Turtle model
-- ---------------------------------------------------------------------------
function T.touch(id) if id then S.dT[id] = true end end

function T.getRec(id, create)
    local r = S.turtles[id]
    if not r and create then
        r = { id = id, st = {}, lastSeen = 0, events = {} }
        S.turtles[id] = r
        T.touch(id)
    end
    return r
end
local getRec = T.getRec

function T.labelOf(r) return r.st.label or ("turtle " .. r.id) end
function T.nameOf(r) return T.labelOf(r) .. " #" .. r.id end
local nameOf = T.nameOf

local function overdueAt(a)
    return a.since + math.floor((a.eta - a.since) * OVERDUE_FACTOR) + OVERDUE_GRACE_MS
end

-- Silent but announced `away` and not overdue: no alert (the card says "away, back by").
function T.isAway(r, t)
    return r.away ~= nil and t - (r.lastSeen or 0) > SILENT_MS and t <= overdueAt(r.away)
end

function T.awayText(r)
    if not r.away then return nil end
    return "away, back by ~" .. T.clockText(r.away.eta)
end

function T.alertOf(r, t)
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

-- Alerts are decided by the owner of the data (leader / pocket) and replicated.
function T.updateAlerts(t)
    if not owner() then return end
    for _, r in pairs(S.turtles) do
        local a = T.alertOf(r, t)
        if a ~= r.alert then
            if a then
                T.logLine("ALERT " .. nameOf(r) .. ": " .. a .. (r.st.reason and (" (" .. r.st.reason .. ")") or ""))
                beep()
            else
                T.logLine("OK " .. nameOf(r) .. ": alert " .. tostring(r.alert) .. " cleared")
            end
            r.alert = a
            T.touch(r.id)
            markDirty()
        end
    end
end

-- Event ids (`eid`) seen: an event re-sent in a catch-up log is logged once.
function T.eventNew(eid)
    if type(eid) ~= "string" then return true end
    if S.evSeen[eid] then return false end
    S.evSeenPos = S.evSeenPos % DEDUPE_MAX + 1
    local old = S.evSeenQ[S.evSeenPos]
    if old then S.evSeen[old] = nil end
    S.evSeenQ[S.evSeenPos] = eid
    S.evSeen[eid] = true
    return true
end

function T.addEvent(r, level, text, at)
    local i = 1
    while r.events[i] and (r.events[i].at or 0) > at do i = i + 1 end
    table.insert(r.events, i, { level = level, text = text, at = at })
    while #r.events > EVENTS_KEEP do table.remove(r.events) end
end

-- ---------------------------------------------------------------------------
-- Commands (non-blocking: pending table, retries driven by tick)
-- ---------------------------------------------------------------------------
function T.cmdText(cmd, params)
    if cmd == "SET" and type(params) == "table" then
        return tostring(params.key) .. "=" .. tostring(params.value)
    end
    return tostring(cmd)
end
local cmdText = T.cmdText

function T.newCmdId()
    S.cmdCounter = S.cmdCounter + 1
    return S.myId .. "-" .. S.boot .. "-" .. S.cmdCounter
end

local function changedCmd(p) S.dP[p.id] = true; T.touch(p.target) end

function T.finishCmd(p, ok, err)
    S.pending[p.id] = nil
    local r = getRec(p.target, true)
    r.cmd = { name = cmdText(p.cmd, p.params), state = ok and "ok" or "failed", err = err, at = now() }
    T.logLine("CMD " .. r.cmd.name .. " -> " .. nameOf(r) .. ": " .. (ok and "ok" or ("FAILED " .. tostring(err))))
    if S.mode == "server" then
        S.done[p.id] = { ok = ok, err = err, target = p.target, at = now() }
        changedCmd(p)
        if p.origin then T.send("ack", p.origin, { id = p.id, ok = ok, err = err, target = p.target }) end
    end
    markDirty()
end

local function transmitCmd(p)
    if S.mode == "server" then
        T.send("cmd", p.target, { id = p.id, cmd = p.cmd, params = p.params })
        p.deadline = now() + ACK_TIMEOUT_MS
    else
        p.server = S.fleetFrom or p.server
        T.send("cmd_relay", p.server, { target = p.target, cmd = p.cmd, params = p.params, id = p.id })
        p.deadline = now() + RELAY_TIMEOUT_MS
    end
end

-- Store-and-forward: hold the command until the turtle is heard again (server), or until the
-- server reports it delivered (pocket).
function T.queueCmd(p)
    p.queued = true
    p.deadline = math.huge
    local r = getRec(p.target, true)
    r.cmd = { name = cmdText(p.cmd, p.params), state = "queued", at = p.queuedAt or now() }
    local first = p.queuedAt == nil
    p.queuedAt = p.queuedAt or now()
    if S.mode == "server" then
        changedCmd(p)
        if first then
            T.logLine("CMD " .. r.cmd.name .. " -> " .. nameOf(r) .. ": queued until it is heard")
            if p.origin then T.send("ack", p.origin, { id = p.id, queued = true, target = p.target }) end
        end
    end
    markDirty()
end

-- The turtle was just heard (leader): send what is queued for it (retried until acked).
function T.deliverQueued(r)
    for _, p in pairs(S.pending) do
        if p.target == r.id and p.queued then
            p.queued = false
            p.tries = 1
            transmitCmd(p)
            r.cmd = { name = cmdText(p.cmd, p.params), state = "pending", tries = 1, at = now() }
            changedCmd(p)
            markDirty()
        end
    end
end

-- Same kind = same target and command (SET: same key). A newer one replaces the older.
local function sameKind(a, target, cmd, params)
    return a.target == target and a.cmd == cmd
        and (cmd ~= "SET" or (type(a.params) == "table" and type(params) == "table" and a.params.key == params.key))
end

-- Send one command to ONE turtle. Returns the command id. On a replica the command is
-- forwarded to the leader (tm_cluster.lua), which owns the queue and alone transmits.
function T.issueCmd(target, cmd, params, origin, id)
    id = id or T.newCmdId()
    params = params or {}
    if S.mode == "server" and not T.isLeader() then
        return T.forwardCmd(target, cmd, params, origin, id)
    end
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
    for _, q in ipairs(old) do T.finishCmd(q, false, "replaced") end
    S.pending[id] = p
    if S.mode == "server" then changedCmd(p) end
    if S.mode == "server" and now() - (r.lastSeen or 0) > HEARD_MS then
        T.queueCmd(p)
        return id
    end
    transmitCmd(p)
    r.cmd = { name = cmdText(cmd, p.params), state = "pending", tries = 1, at = now() }
    markDirty()
    return id
end

function T.onAck(msg)
    local p = S.pending[msg.id]
    if not p then return end
    if S.mode == "server" then
        if not T.isLeader() or msg.from ~= p.target then return end
    elseif msg.from ~= p.target and msg.from ~= p.server and tonumber(msg.target) ~= p.target then
        return
    end
    if msg.queued then
        if S.mode == "pocket" then T.queueCmd(p) end
        return
    end
    T.finishCmd(p, msg.ok == true, msg.err)
end

-- Retries and expiry: only the owner of the queue (leader, or a pocket for its own relays).
function T.tickCmds(t)
    if owner() then
        local list = {}
        for _, p in pairs(S.pending) do list[#list + 1] = p end
        for _, p in ipairs(list) do
            if t - (p.created or t) > QUEUE_EXPIRE_MS then
                T.finishCmd(p, false, "expired")
            elseif not p.queued and t >= (p.deadline or 0) then
                local maxTries = (S.mode == "server") and (1 + ACK_RETRIES) or (1 + RELAY_RETRIES)
                if p.tries < maxTries then
                    p.tries = p.tries + 1
                    transmitCmd(p)
                    local r = getRec(p.target, true)
                    if r.cmd then r.cmd.tries = p.tries end
                    markDirty()
                elseif S.mode == "server" then
                    T.queueCmd(p)          -- no ack: keep it until the turtle is heard again
                else
                    T.finishCmd(p, false, "no reply from server")
                end
            end
        end
    end
    for id, d in pairs(S.done) do
        if t - (d.at or 0) > DONE_KEEP_MS then S.done[id] = nil end
    end
end

-- ---------------------------------------------------------------------------
-- Replication format: snapshot (everything) and delta (what changed since the last one)
-- ---------------------------------------------------------------------------
local function packRec(r)
    if not r then return nil end
    return { id = r.id, st = r.st, lastSeen = r.lastSeen, events = r.events, away = r.away,
        cmd = r.cmd, alert = r.alert, mk = r.mk }
end

local function unpackRec(id, t)
    local r = copy(t)
    r.id = id
    r.st = type(r.st) == "table" and r.st or {}
    r.events = type(r.events) == "table" and r.events or {}
    r.lastSeen = tonumber(r.lastSeen) or 0
    return r
end

-- Replace a record in place (UIs and callers may hold the table).
local function putRec(id, t)
    local r, n = S.turtles[id], unpackRec(id, t)
    if not r then S.turtles[id] = n; return end
    for k in pairs(r) do r[k] = nil end
    for k, v in pairs(n) do r[k] = v end
end

local function unpackCmd(p)
    local q = copy(p)
    q.tries = 1
    q.deadline = math.huge
    return q
end

function T.snapshot()
    local turtles, pend = {}, {}
    for id, r in pairs(S.turtles) do turtles[id] = packRec(r) end
    for id, p in pairs(S.pending) do if not p.forwarded then pend[id] = packCmd(p) end end
    return { turtles = turtles, homes = S.homes, pending = pend, done = S.done, log = S.log, armies = S.armies }
end

-- Leader: collect the changes. Returns the delta table and whether it is urgent (queue or
-- homes changed: replicas should learn at once, the rest waits for the 5 s heartbeat).
function T.takeDelta()
    local d = { turtles = {}, homes = {}, pending = {}, done = {}, log = S.logOut }
    local any, urgent = #S.logOut > 0, false
    for id in pairs(S.dT) do d.turtles[id] = packRec(S.turtles[id]) or false; any = true end
    for id in pairs(S.dH) do d.homes[id] = S.homes[id] or false; any, urgent = true, true end
    for id in pairs(S.dP) do
        d.pending[id] = packCmd(S.pending[id]) or false
        d.done[id] = S.done[id] or false
        any, urgent = true, true
    end
    if T.army then
        local da = T.army.takeDelta()
        if da then d.armies = da; any, urgent = true, true end
    end
    S.dT, S.dH, S.dP, S.logOut = {}, {}, {}, {}
    if not any then return nil end
    S.dbSeq = S.dbSeq + 1
    if urgent then T.saveDb() end
    return d, urgent
end

function T.pendingUrgent()
    return next(S.dP) ~= nil or next(S.dH) ~= nil or next(S.dA or {}) ~= nil
end

local function syncForwarded()
    if T.syncOutbox then T.syncOutbox() end
end

function T.applySnapshot(epoch, seq, db)
    if type(db) ~= "table" then return false end
    local turtles = type(db.turtles) == "table" and db.turtles or {}
    for id in pairs(S.turtles) do if type(turtles[id]) ~= "table" then S.turtles[id] = nil end end
    for id, r in pairs(turtles) do if type(r) == "table" then putRec(id, r) end end
    S.pending, S.done = {}, {}
    for id, p in pairs(type(db.pending) == "table" and db.pending or {}) do
        if type(p) == "table" then S.pending[id] = unpackCmd(p) end
    end
    for id, d in pairs(type(db.done) == "table" and db.done or {}) do
        if type(d) == "table" then S.done[id] = d end
    end
    S.homes = type(db.homes) == "table" and db.homes or {}
    if T.army then T.army.applySnapshot(db.armies) end
    if type(db.log) == "table" then
        S.log = {}
        for _, l in ipairs(db.log) do if type(l) == "string" then S.log[#S.log + 1] = l end end
        rewriteLog()
    end
    S.epoch, S.dbSeq = epoch, seq
    S.dT, S.dH, S.dP, S.logOut = {}, {}, {}, {}
    syncForwarded()
    T.saveHomes()
    T.saveDb()
    markDirty()
    return true
end

function T.applyDelta(seq, d)
    if type(d) ~= "table" then return end
    for id, r in pairs(type(d.turtles) == "table" and d.turtles or {}) do
        if r then putRec(id, r) else S.turtles[id] = nil end
    end
    if T.army and d.armies then T.army.applyDelta(d.armies) end
    local homes = false
    for id, h in pairs(type(d.homes) == "table" and d.homes or {}) do
        S.homes[id] = h or nil
        homes = true
    end
    local cmds = false
    for id, p in pairs(type(d.pending) == "table" and d.pending or {}) do
        S.pending[id] = p and unpackCmd(p) or nil
        cmds = true
    end
    for id, x in pairs(type(d.done) == "table" and d.done or {}) do S.done[id] = x or nil end
    if type(d.log) == "table" and #d.log > 0 then logInsert(d.log) end
    S.dbSeq = seq
    if cmds then syncForwarded() end
    if homes then T.saveHomes() end
    if homes or cmds then T.saveDb() end
    markDirty()
end

return T
