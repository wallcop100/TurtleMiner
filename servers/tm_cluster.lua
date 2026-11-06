-- Version: 1.2.0
-- TurtleMiner server cluster (docs/CLUSTER_GPS_PLAN.md section 2, docs/PROTOCOL.md "Cluster").
-- Every server PC runs this. Over any modem mix (the radio part relays across wired,
-- wireless and ender modems) the PCs find each other with `cluster_hello`, pick ONE leader
-- and keep a copy of the leader's database:
--   * election: newest data (epoch, seq) first, then the lowest computer ID. A live leader is
--     never pushed out (no flapping): a rebooted old leader rejoins as a replica.
--   * the leader sends changes (`cluster_delta`) at once when the command queue or homes
--     change, else every 5 s (the heartbeat); a replica that misses one asks for a snapshot.
--   * leader silent for 15 s: the replicas elect again (newest seq wins) and the winner takes
--     over, with the replicated homes and queued commands.
--   * UI commands on a replica (and pocket `cmd_relay`s it receives) are forwarded to the
--     leader (`cluster_fwd`) and resent until they show up in the replicated queue.
--   * two leaders that meet (a healed split): higher epoch, then lower ID stays; the other
--     hands over its queued commands and homes and becomes a replica.
--   * hellos carry the PC's mesh-update summary (`vs`, `us`) and program version (`ver`).
local T = ...
local S = T.S

local HELLO_MS   = 5000    -- every member: hello (membership + its data version)
local DELTA_MS   = 5000    -- leader: heartbeat delta even when nothing changed
local DEAD_MS    = 15000   -- a member (or the leader) not heard for this long is gone
local JOIN_MS    = 3000    -- after boot: wait this long for a leader before electing
local ELECT_MS   = 2000    -- leader gone: collect fresh hellos for this long, then elect
local RESEND_MS  = 5000    -- replica: resend forwarded commands not yet in the queue
local SNAPREQ_MS = 3000
local ANNOUNCE_MS = 1000

local C = {
    role = "joining",      -- joining | electing | replica | leader
    leader = nil, leaderEpoch = 0, leaderAt = 0,
    since = 0, electAt = 0, waitFor = nil, waitSince = 0,
    members = {},          -- id -> {id, role, leader, epoch, seq, roles, label, at}
    outbox = {},           -- forwarded commands not yet seen in the leader's queue
    lastHello = 0, lastDelta = 0, lastAnnounce = 0, needSnap = false, snapReqAt = 0,
    takeovers = 0,
}
T.C = C
T.DEAD_MS = DEAD_MS

local now = T.now
local function send(kind, to, body) return T.send(kind, to, body) end

local function live(m, t) return m and not m.dead and (t or now()) - (m.at or 0) <= DEAD_MS end
T.memberLive = live

-- a beats b as leader: higher epoch, then lower id
local function beats(a, ea, b, eb)
    ea, eb = ea or 0, eb or 0
    if ea ~= eb then return ea > eb end
    return a < b
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------
local function hello(t)
    local body = { role = C.role, leader = C.leader, epoch = S.epoch, dseq = S.dbSeq,
        roles = T.roles, label = os.getComputerLabel and os.getComputerLabel() or nil }
    if T.mesh then
        T.addSummary(body)
        body.ver = T.myVersion()
    end
    send("cluster_hello", "cluster", body)
    C.lastHello = t
end

local function announce(t)
    send("cluster_leader", "cluster", { epoch = S.epoch, dseq = S.dbSeq })
    C.lastAnnounce = t
end

local function anyMember(t)
    for _, m in pairs(C.members) do if live(m, t) then return true end end
    return false
end

-- Leader: send what changed. Returns true when something was sent.
local function flush(t, force)
    local d = T.takeDelta()
    if (d or force) and anyMember(t) then
        send("cluster_delta", "cluster", { epoch = S.epoch, base = d and S.dbSeq - 1 or S.dbSeq, dseq = S.dbSeq, d = d })
    end
    C.lastDelta = t
end

local function sendSnapshot(t, to)
    flush(t, false)        -- changes already in the snapshot must not come again as a delta
    send("cluster_snapshot", to, { epoch = S.epoch, dseq = S.dbSeq, db = T.snapshot() })
end

local function sendOutbox(t, all)
    if C.role ~= "replica" or not C.leader then return end
    for _, e in pairs(C.outbox) do
        if all or t - (e.sentAt or 0) >= RESEND_MS then
            send("cluster_fwd", C.leader, { op = "cmd", id = e.id, target = e.target, cmd = e.cmd,
                params = e.params, origin = e.origin })
            e.sentAt = t
        end
    end
end

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
local function follow(id, epoch, t)
    local changed = C.leader ~= id
    C.role, C.leader, C.leaderEpoch, C.leaderAt = "replica", id, epoch or 0, t
    C.waitFor = nil
    if changed then
        C.needSnap, C.snapReqAt = true, 0
        T.logLine("cluster: following leader #" .. id)
        sendOutbox(t, true)
    end
    T.markDirty()
end

local function becomeLeader(t, why)
    local e = S.epoch
    for _, m in pairs(C.members) do if (m.epoch or 0) > e then e = m.epoch end end
    S.epoch = e + 1
    C.role, C.leader, C.leaderEpoch, C.leaderAt, C.waitFor = "leader", S.myId, S.epoch, t, nil
    C.needSnap = false
    C.takeovers = C.takeovers + 1
    -- Replicated queue: everything waits for the turtle to be heard (turtles re-ack known ids).
    local mine = {}
    for id, p in pairs(S.pending) do
        if p.forwarded then mine[#mine + 1] = id
        else
            p.queued, p.deadline, p.tries = true, math.huge, 1
            p.queuedAt = p.queuedAt or t
            S.dP[id] = true
        end
    end
    for _, id in ipairs(mine) do S.pending[id] = nil end
    T.logLine("cluster: #" .. S.myId .. " is the leader (epoch " .. S.epoch .. ", " .. why .. ")")
    -- Our own forwarded commands that never reached the old leader.
    local out = C.outbox
    C.outbox = {}
    for id, e in pairs(out) do
        if not S.pending[id] and not S.done[id] then T.issueCmd(e.target, e.cmd, e.params, e.origin, id) end
    end
    S.lastFleet = 0
    T.saveDb()
    announce(t)
    sendSnapshot(t, "cluster")
    T.markDirty()
end

-- Hand our queue and homes to the leader that beat us, then follow it.
local function stepDown(id, epoch, t)
    local pend = {}
    for pid, p in pairs(S.pending) do if not p.forwarded then pend[pid] = T.packCmd(p) end end
    send("cluster_fwd", id, { op = "merge", pending = pend, homes = S.homes })
    T.logLine("cluster: #" .. id .. " leads (epoch " .. tostring(epoch) .. "), stepping down")
    C.role = "replica"
    follow(id, epoch, t)
end

local function elect(t)
    local best, be, bs = S.myId, S.epoch, S.dbSeq
    for id, m in pairs(C.members) do
        if live(m, t) and id ~= C.waitFor then
            local e, s = m.epoch or 0, m.seq or 0
            if e > be or (e == be and (s > bs or (s == bs and id < best))) then best, be, bs = id, e, s end
        end
    end
    if best == S.myId then
        becomeLeader(t, C.role == "joining" and "elected" or "took over")
    else
        C.role, C.waitFor, C.waitSince = "joining", best, t
    end
end

-- A message from a node that claims to lead (cluster_leader, its hello, delta or snapshot).
local function leaderClaim(id, epoch, t)
    if C.role == "leader" then
        if id == S.myId then return end
        if beats(id, epoch, S.myId, S.epoch) then stepDown(id, epoch, t)
        elseif t - C.lastAnnounce >= ANNOUNCE_MS then announce(t) end
        return
    end
    if C.leader == id then
        C.leaderAt, C.leaderEpoch = t, epoch or C.leaderEpoch
        if C.role ~= "replica" then follow(id, epoch, t) end
        return
    end
    local cur = C.leader and C.members[C.leader]
    if not C.leader or not live(cur, t) or beats(id, epoch, C.leader, C.leaderEpoch) then follow(id, epoch, t) end
end

-- ---------------------------------------------------------------------------
-- Leader: forwarded work
-- ---------------------------------------------------------------------------
local function sameKindPending(target, cmd, params)
    for _, p in pairs(S.pending) do
        if p.target == target and p.cmd == cmd and (cmd ~= "SET" or (type(p.params) == "table"
            and type(params) == "table" and p.params.key == params.key)) then return true end
    end
    return false
end

local function onForward(msg)
    if msg.op == "cmd" then
        local id, target = msg.id, tonumber(msg.target)
        if type(id) ~= "string" or not target or not T.CMDS[msg.cmd] then return end
        local p, d = S.pending[id], S.done[id]
        if p then
            if msg.origin and not p.origin then p.origin = msg.origin end
            S.dP[id] = true          -- the replica learns it arrived
        elseif d then
            S.dP[id] = true
            if msg.origin then send("ack", msg.origin, { id = id, ok = d.ok, err = d.err, target = d.target }) end
        else
            T.issueCmd(target, msg.cmd, type(msg.params) == "table" and msg.params or {}, msg.origin, id)
        end
    elseif msg.op == "army" then
        local b = msg.body
        if type(b) == "table" and T.army and T.army.KINDS and T.army.KINDS[b.kind] then
            b.from = msg.from
            T.army.handle(b)
            T.markDirty()
        end
    elseif msg.op == "merge" then
        local n = 0
        for id, p in pairs(type(msg.pending) == "table" and msg.pending or {}) do
            if type(p) == "table" and tonumber(p.target) and T.CMDS[p.cmd] and not S.pending[id] and not S.done[id]
                and not sameKindPending(p.target, p.cmd, p.params) then
                T.issueCmd(p.target, p.cmd, type(p.params) == "table" and p.params or {}, p.origin, id)
                n = n + 1
            end
        end
        local h = 0
        for id, rec in pairs(type(msg.homes) == "table" and msg.homes or {}) do
            local cur = S.homes[id]
            if type(rec) == "table" and (not cur or (tonumber(rec.at) or 0) > (tonumber(cur.at) or 0)) then
                S.homes[id], S.dH[id] = rec, true
                h = h + 1
            end
        end
        if h > 0 then T.saveHomes() end
        T.logLine("cluster: merged #" .. msg.from .. ": " .. n .. " command(s), " .. h .. " home(s)")
    end
end

-- ---------------------------------------------------------------------------
-- Entry points (called from tm_radio.lua / the tick loop)
-- ---------------------------------------------------------------------------
function T.clusterMessage(msg)
    local t = now()
    local id, k = msg.from, msg.kind
    local m = C.members[id]
    if not m or not live(m, t) then
        m = m or { id = id }
        if C.role == "leader" then T.logLine("cluster: PC #" .. id .. " joined") end
    end
    C.members[id] = m
    m.at, m.dead = t, nil
    if k == "cluster_hello" then
        m.role, m.leader, m.roles, m.label = msg.role, msg.leader, msg.roles, msg.label
        m.epoch, m.seq = tonumber(msg.epoch) or 0, tonumber(msg.dseq) or 0
        if msg.role == "leader" then leaderClaim(id, m.epoch, t) end
        -- A PC that is looking for the cluster learns about us at once (not in 5 s).
        if (msg.role == "joining" or msg.role == "electing") and t - C.lastHello >= ANNOUNCE_MS then hello(t) end
        if C.role == "leader" and msg.leader ~= S.myId and t - C.lastAnnounce >= ANNOUNCE_MS then announce(t) end
    elseif k == "cluster_leader" or k == "cluster_delta" or k == "cluster_snapshot" then
        m.role, m.epoch, m.seq = "leader", tonumber(msg.epoch) or 0, tonumber(msg.dseq) or 0
        leaderClaim(id, m.epoch, t)
        if C.role ~= "replica" or C.leader ~= id then return end
        if k == "cluster_delta" then
            if msg.epoch == S.epoch and msg.base == S.dbSeq and msg.dseq ~= S.dbSeq then
                T.applyDelta(msg.dseq, msg.d)
            elseif not (msg.epoch == S.epoch and msg.dseq == S.dbSeq) then
                C.needSnap = true
            end
        elseif k == "cluster_snapshot" and (msg.to == S.myId or msg.to == "cluster") then
            if T.applySnapshot(tonumber(msg.epoch) or 0, tonumber(msg.dseq) or 0, msg.db) then C.needSnap = false end
        end
    elseif k == "cluster_snap_req" then
        if C.role == "leader" and msg.to == S.myId then sendSnapshot(t, id) end
    elseif k == "cluster_fwd" then
        if C.role == "leader" and msg.to == S.myId then onForward(msg) end
    end
    T.markDirty()
end

-- Replica: forward a UI / pocket command to the leader. Shown as pending at once; the
-- replicated queue takes over when the leader has it.
function T.forwardCmd(target, cmd, params, origin, id)
    local t = now()
    C.outbox[id] = { id = id, target = target, cmd = cmd, params = params, origin = origin, at = t, sentAt = 0 }
    S.pending[id] = { id = id, target = target, cmd = cmd, params = params, created = t, tries = 1,
        deadline = math.huge, forwarded = true }
    local r = T.getRec(target, true)
    r.cmd = { name = T.cmdText(cmd, params), state = "pending", tries = 1, at = t }
    sendOutbox(t, false)
    T.markDirty()
    return id
end

-- Replica: forward an army action (army_new / army_set / army_release ...) to the leader.
-- Returns true when sent; the result comes back through the replicated S.armies.
function T.forwardArmy(body)
    if C.role ~= "replica" or not C.leader then return nil, "no leader yet" end
    send("cluster_fwd", C.leader, { op = "army", body = body })
    return true
end

-- After replicated data arrived: drop forwarded commands the leader has, keep the rest shown.
function T.syncOutbox()
    local t = now()
    for id, e in pairs(C.outbox) do
        local p = S.pending[id]
        if (p and not p.forwarded) or S.done[id] then
            C.outbox[id] = nil
        elseif t - e.at > T.QUEUE_EXPIRE_MS then
            C.outbox[id] = nil
            S.pending[id] = nil
        elseif not p then
            S.pending[id] = { id = id, target = e.target, cmd = e.cmd, params = e.params, created = e.at,
                tries = 1, deadline = math.huge, forwarded = true }
        end
    end
end

-- Update server arbitration: of the live PCs with /files/, the lowest ID answers turtles.
function T.updateServes()
    if not (T.roles and T.roles.update) then return false end
    local t = now()
    for id, m in pairs(C.members) do
        if id < S.myId and live(m, t) and type(m.roles) == "table" and m.roles.update then return false end
    end
    return true
end

-- GitHub pull ("Check now", updater --pull): this PC can (HTTP + update role + github_pull.lua).
function T.canPull()
    return S.mode == "server" and http ~= nil and T.roles ~= nil and T.roles.update == true
        and T.update ~= nil and T.update.hasPuller ~= nil and T.update.hasPuller()
end

-- Of the live PCs that can pull, the lowest ID answers `pull_req`.
function T.pullServes()
    if not T.canPull() then return false end
    local t = now()
    for id, m in pairs(C.members) do
        if id < S.myId and live(m, t) and type(m.roles) == "table" and m.roles.update and m.roles.http then return false end
    end
    return true
end

function T.clusterStart()
    local t = now()
    C.since = t
    C.role = "joining"
    if not S.netOk then becomeLeader(t, "no modem: alone") return end
    hello(t)
end

function T.clusterTick(t)
    if S.mode ~= "server" then return end
    if t - C.lastHello >= HELLO_MS then hello(t) end
    if C.role == "leader" then
        if T.pendingUrgent() or t - C.lastDelta >= DELTA_MS then flush(t, true) end
        return
    end
    if C.role == "replica" then
        if t - C.leaderAt > DEAD_MS then
            local m = C.members[C.leader]
            if m then m.dead = true end
            T.logLine("cluster: leader #" .. tostring(C.leader) .. " silent " .. math.floor(DEAD_MS / 1000) .. " s")
            C.role, C.leader, C.electAt = "electing", nil, t + ELECT_MS
            hello(t)
            return
        end
        if C.needSnap and t - C.snapReqAt >= SNAPREQ_MS then
            send("cluster_snap_req", C.leader, { epoch = S.epoch, dseq = S.dbSeq })
            C.snapReqAt = t
        end
        sendOutbox(t, false)
    elseif C.role == "electing" then
        if t >= C.electAt then elect(t) end
    elseif C.role == "joining" then
        if C.waitFor then
            if t - C.waitSince > DEAD_MS then
                local m = C.members[C.waitFor]
                if m then m.dead = true end
                C.waitFor = nil
                elect(t)
            end
        elseif t - C.since >= JOIN_MS or not S.netOk then
            elect(t)
        end
    end
end

-- Short text for the UI footer / header.
function T.clusterText()
    if S.mode ~= "server" then return nil end
    local t, n = now(), 1
    for _, m in pairs(C.members) do if live(m, t) then n = n + 1 end end
    local r = C.role == "leader" and "LEAD" or (C.role == "replica" and ("ldr#" .. tostring(C.leader)) or C.role)
    return r .. (n > 1 and (" " .. n .. "pc") or "")
end

return T
