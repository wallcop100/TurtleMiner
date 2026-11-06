-- Version: 1.0.5
-- TurtleMiner GPS constellation from the server PCs (docs/CLUSTER_GPS_PLAN.md section 3).
-- Offered, never required. The cluster leader counts the PCs with a wireless or ender modem;
-- with >= 4 and a good layout (measured, not coplanar, >= 6 blocks apart) it offers
-- `GPS possible with N PCs: [Set up] [Later] [Never]` on the monitor and on each eligible
-- PC's terminal. One confirm sets up all: distances are measured on a raw modem channel,
-- then the layout is anchored silently (a PC that already gets a GPS fix, or samples from
-- turtles that know their world position), else only the PCs needed (3, plus one number)
-- are asked for F3 coordinates on their own terminal, each entry checked at once.
-- Hosts then answer gps.CHANNEL_GPS pings (like rom `gps host`) from their wireless modem.
--
-- WHICH POINT IS MEASURED (CC:Tweaked, WirelessModemBlockEntity.Peripheral#getPosition):
--   Vec3.atLowerCornerOf(modemBlockPos.relative(modemFacing)), i.e. the block the modem is
--   ATTACHED TO (the computer block for a modem touching the PC), not the modem block. The
--   `modem_message` distance is between two such positions (WirelessNetwork delivers the
--   straight-line distance of the endpoints' getPosition()). So the position we solve and
--   announce is the integer block position of the computer ("Targeted Block" in F3), exactly
--   what a turtle (its own block) measures against. A modem on a PC's wired side is not used.
--
-- Messages (docs/PROTOCOL.md "GPS"): gps_info, gps_measure, gps_dist, gps_locate, gps_fix,
-- gps_cmd, gps_answer, gps_reply, gps_state, gps_sample. Raw modem channel CH_BEACON carries
-- unsigned distance beacons (a forger cannot fake the distance; the leader cross-checks).
-- Hooks elsewhere: T.gpsMessage (tm_radio), T.gpsRaw (tm_radio netLoop), T.gpsBanner /
-- T.gpsPrompt / T.gpsKey (tm_ui), views gps / cluster / gpsask (below).
local T = ...
local S = T.S

local path = T.modulePath and T.modulePath("tm_gpssolve")
if not path then return end
local fnS = loadfile(path, nil, _ENV)
if not fnS then return end
local M = fnS(T) or T.gpssolve

local FILE = ".tm_gps"
local CH_BEACON = 65501
local CHANNEL_GPS = (gps and gps.CHANNEL_GPS) or 65534
local EVAL_MS, INFO_MS, STATE_MS = 60000, 20000, 5000
local INFO_LIVE_MS = 70000
local LATER_MS = 6 * 3600 * 1000
local now = T.now

local V = { never = false, st = "idle", hosts = {}, asks = {}, kinds = {}, rev = 0 }   -- replicated view
local L = nil            -- leader-only working state
local heard = {}         -- round -> id -> distance (beacons heard)
local jobs = {}          -- {at, fn}
local loc = nil          -- non-blocking locate: {untilMs, reps, round}
local samples = {}       -- pc id -> list of {x,y,z,d}  (from turtles)
local lastOpen, lastInfo, lastState = 0, 0, 0
local hosting, mypos = false, nil
local info = {}          -- id -> {mk, boot, at}
local errMsg = {}        -- last rejection text for this PC's prompt

local G = {}
T.gps = G
G.view = V
G.samples = samples
function G.leaderState() return L end   -- for tests
G.DRIFT_MS = 600000                      -- re-measure period (10 min; tests shorten it)

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------
local function save()
    local h = fs.open(FILE, "w")
    if h then h.write(textutils.serialize(V)); h.close() end
end
local function load()
    local h = fs.open(FILE, "r")
    if not h then return end
    local s = h.readAll(); h.close()
    local t = textutils.unserialize(s)
    if type(t) == "table" then
        for k, v in pairs(t) do V[k] = v end
        if V.st ~= "on" then V.st = "idle"; V.asks = {}; V.offer = nil end
    end
end

-- ---------------------------------------------------------------------------
-- Hardware
-- ---------------------------------------------------------------------------
local function wireless()
    local r = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local ok, w = pcall(peripheral.call, name, "isWireless")
            if ok and w then r[#r + 1] = name end
        end
    end
    return r
end

local function openChannels()
    local reply = os.getComputerID() % 65500
    for _, side in ipairs(wireless()) do
        pcall(peripheral.call, side, "open", CH_BEACON)
        pcall(peripheral.call, side, "open", reply)
        if hosting then pcall(peripheral.call, side, "open", CHANNEL_GPS)
        else pcall(peripheral.call, side, "close", CHANNEL_GPS) end
    end
    lastOpen = now()
end

local function transmitAll(ch, reply, msg)
    for _, side in ipairs(wireless()) do pcall(peripheral.call, side, "transmit", ch, reply, msg) end
end

local function myKind() return S.modemKind == "ender" and "ender" or "basic" end
local function isWireless() return #wireless() > 0 end

-- Applies V.hosts to this PC: start / stop answering GPS pings.
local function applyHosting()
    local h = V.hosts[S.myId]
    local on = h and h.st == "hosting" or false
    if on and (not hosting or not mypos or mypos.x ~= h.x or mypos.y ~= h.y or mypos.z ~= h.z) then
        hosting, mypos = true, { x = h.x, y = h.y, z = h.z }
        T.logLine(string.format("GPS host: answering as %d %d %d", h.x, h.y, h.z))
        openChannels()
    elseif not on and hosting then
        hosting, mypos = false, nil
        T.logLine("GPS host: stopped" .. (h and h.why and (" (" .. h.why .. ")") or ""))
        openChannels()
    end
end

function G.wanted() return hosting end
function G.loop() while true do sleep(30) end end    -- hosting itself runs from the radio loop (T.gpsRaw)

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------
local handle

local function toLeader(kind, body)
    body = body or {}
    if T.isLeader() then
        local m = {}
        for k, v in pairs(body) do m[k] = v end
        m.kind, m.from = kind, S.myId
        handle(m)
    elseif T.C and T.C.leader then
        T.send(kind, T.C.leader, body)
    end
end

local function publish(t)
    V.rev = (V.rev or 0) + 1
    lastState = t or now()
    local body = { never = V.never, st = V.st, later = V.later, offer = V.offer, hosts = V.hosts, asks = V.asks,
        kinds = V.kinds, rev = V.rev, note = V.note, n = V.n }
    T.send("gps_state", "cluster", body)
    save()
    applyHosting()
    T.markDirty()
end

local function job(afterMs, fn) jobs[#jobs + 1] = { at = now() + afterMs, fn = fn } end

-- ---------------------------------------------------------------------------
-- Measuring (every wireless PC beacons once per round; everyone records the distance)
-- ---------------------------------------------------------------------------
local function onMeasure(round)
    if not isWireless() then return end
    job(1500, function() transmitAll(CH_BEACON, CH_BEACON, { tmgps = "b", id = S.myId, round = round }) end)
    job(5000, function()
        local d = {}
        for id, v in pairs(heard[round] or {}) do d[id] = v end
        toLeader("gps_dist", { round = round, d = d })
    end)
    for r in pairs(heard) do if r < round - 3 then heard[r] = nil end end
end

local function onLocate(round)
    if not isWireless() or hosting then return end
    loc = { untilMs = now() + 2500, reps = {}, round = round }
    transmitAll(CHANNEL_GPS, os.getComputerID() % 65500, "PING")
    job(2700, function()
        local l = loc
        loc = nil
        if not l then return end
        local sph = {}
        for _, r in ipairs(l.reps) do sph[#sph + 1] = r end
        local p = M.trilat(sph)
        local out = {}
        if p then
            local r = M.round(p)
            local ok = true
            for _, s in ipairs(sph) do if math.abs(M.dist(r, s) - s.d) > M.TOL then ok = false end end
            if ok then out = { x = r.x, y = r.y, z = r.z } end
        end
        out.round = l.round
        toLeader("gps_fix", out)
    end)
end

-- Raw modem_message from the radio loop.
function G.gpsRaw(ev)
    local side, ch, reply, msg, dist = ev[2], ev[3], ev[4], ev[5], ev[6]
    if type(dist) ~= "number" then return end
    if ch == CH_BEACON and type(msg) == "table" and msg.tmgps == "b" and type(msg.id) == "number" and msg.id ~= S.myId then
        local r = msg.round
        heard[r] = heard[r] or {}
        heard[r][msg.id] = dist
    elseif ch == CHANNEL_GPS and msg == "PING" and hosting and mypos then
        pcall(peripheral.call, side, "transmit", reply, CHANNEL_GPS, { mypos.x, mypos.y, mypos.z })
    elseif loc and type(msg) == "table" and #msg == 3 and type(msg[1]) == "number" and type(msg[2]) == "number"
        and type(msg[3]) == "number" then
        loc.reps[#loc.reps + 1] = { x = msg[1], y = msg[2], z = msg[3], d = dist }
    end
end
T.gpsRaw = G.gpsRaw

-- ---------------------------------------------------------------------------
-- Leader
-- ---------------------------------------------------------------------------
local function eligible(t)
    local ids = {}
    if isWireless() then ids[#ids + 1] = S.myId end
    for id, i in pairs(info) do
        local m = T.C and T.C.members[id]
        if id ~= S.myId and t - i.at <= INFO_LIVE_MS and (not m or T.memberLive(m, t)) then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

local function newLeaderState(t)
    L = { D = {}, lastEval = 0, lastMeasure = t, dirty = true, known = {}, nextEval = 0 }
    if V.st ~= "on" then V.st = "idle"; V.asks = {}; V.offer = nil end
end

local function startMeasure(t, purpose)
    local ids = eligible(t)
    local round = math.floor(t / 1000)
    L.rnd = { id = round, at = t, purpose = purpose, expect = ids, got = {} }
    L.dirty = false
    T.send("gps_measure", "cluster", { round = round })
    onMeasure(round)
end

-- Complete matrix: drop the PC with most missing pairs until every pair has a distance.
local function matrixOf(rnd)
    local D, ids = {}, {}
    for id in pairs(rnd.got) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, a in ipairs(ids) do
        for _, b in ipairs(ids) do
            if a < b then
                local x, y = rnd.got[a][b], rnd.got[b][a]
                if x and y then D[M.key(a, b)] = (x + y) / 2 else D[M.key(a, b)] = x or y end
            end
        end
    end
    while true do
        local worst, wn = nil, 0
        for _, a in ipairs(ids) do
            local n = 0
            for _, b in ipairs(ids) do if a ~= b and not D[M.key(a, b)] then n = n + 1 end end
            if n > wn then worst, wn = a, n end
        end
        if not worst then break end
        for i, v in ipairs(ids) do if v == worst then table.remove(ids, i); break end end
    end
    return D, ids
end

local function setOffer(ids, why)
    local was = V.offer ~= nil
    if ids then
        V.offer = ids
        V.n = #ids
        V.st = "offer"
    else
        V.offer = nil
        if V.st == "offer" then V.st = "idle" end
    end
    local noteChanged = V.note ~= why
    V.note = why
    if (ids ~= nil) ~= was or noteChanged then
        if ids then T.logLine("GPS: possible with " .. #ids .. " PCs") end
        publish()
    end
end

local function hostIds()
    local r = {}
    for id, h in pairs(V.hosts) do r[#r + 1] = id end
    table.sort(r)
    return r
end

local function sampleKnown(ids)
    local known = {}
    for _, id in ipairs(ids) do
        local list = samples[id]
        if list and #list >= 4 then
            local p, worst = M.trilat(list)
            if p then
                local r = M.round(p)
                local ok = true
                for _, s in ipairs(list) do if math.abs(M.dist(r, s) - s.d) > M.TOL then ok = false end end
                if ok then known[id] = r end
            end
        end
    end
    return known
end

local function finishSetup(pos, ids, t)
    V.hosts = {}
    for _, id in ipairs(ids) do
        local p = pos[id]
        V.hosts[id] = { x = p.x, y = p.y, z = p.z, st = "hosting" }
    end
    V.kinds = {}
    for _, id in ipairs(ids) do V.kinds[id] = (id == S.myId) and myKind() or (info[id] and info[id].mk) or "basic" end
    V.st, V.asks, V.offer, V.note = "on", {}, nil, nil
    L.lastMeasure = t
    T.logLine("GPS: constellation up with " .. #ids .. " hosts")
    publish(t)
end

local function advance(t)
    local rs = L.setup
    local res = M.resolve(L.known, rs.D, rs.ids)
    if res.pos then return finishSetup(res.pos, rs.ids, t) end
    if res.fail then
        T.logLine("GPS: setup failed: " .. res.fail)
        V.st, V.asks, V.offer, V.note = "idle", {}, nil, "setup failed: " .. res.fail
        L.setup = nil
        L.nextEval = t + 300000
        return publish(t)
    end
    V.asks = {}
    if res.need == "xyz" then
        for _, id in ipairs(res.ids) do V.asks[id] = { kind = "xyz" } end
    else
        V.asks[res.id] = { kind = "axis", axis = res.axis, cands = res.cands }
    end
    V.st = "asking"
    publish(t)
end

local function beginSetup(t)
    L.setup = { phase = "measure", ids = V.offer }
    V.st = "setup"
    V.asks = {}
    startMeasure(t, "setup")
    publish(t)
end

-- Distances measured: act on the purpose.
-- Why no offer, in words a player can act on.
function G.explain(why, heard, total)
    why = tostring(why or "unknown")
    if why == "need 4 PCs" or why:find("^missing distance") then
        return ("only %d of %d PCs heard each other by radio; GPS needs 4. Move them closer "
            .. "(basic modems reach 64 blocks below Y 96) or use ender modems"):format(heard, total)
    elseif why == "all in one plane" then
        return "PCs are all at one height (or in one flat plane): raise or lower one by 2+ blocks"
    elseif why == "all in one line" then
        return "PCs are in a straight line: move one sideways"
    end
    return "layout not usable: " .. why
end

local function measured(t)
    local rnd = L.rnd
    L.rnd = nil
    local D, ids = matrixOf(rnd)
    if rnd.purpose == "offer" then
        if V.st ~= "idle" and V.st ~= "offer" then return end
        local P, why = M.layout(ids, D)
        if P then setOffer(ids) else setOffer(nil, G.explain(why, #ids, #rnd.expect)) end
        L.lastEval = t
    elseif rnd.purpose == "setup" then
        if not L.setup or V.st ~= "setup" then return end
        local P, why = M.layout(ids, D)
        if not P then
            L.setup = nil
            V.st, V.offer, V.note = "idle", nil, "setup stopped: " .. tostring(why)
            return publish(t)
        end
        L.setup.D, L.setup.ids = D, ids
        L.known = {}
        L.setup.phase = "locate"
        L.setup.at = t
        L.fixes = {}
        T.send("gps_locate", "cluster", { round = rnd.id })
        onLocate(rnd.id)
    elseif rnd.purpose == "drift" then
        L.lastMeasure = t
        local hosts = hostIds()
        local reported = {}
        for _, id in ipairs(ids) do reported[id] = true end
        local pos, check = {}, {}
        for _, id in ipairs(hosts) do
            local h = V.hosts[id]
            pos[id] = { x = h.x, y = h.y, z = h.z }
            if reported[id] then check[#check + 1] = id else
                if h.st == "hosting" then h.st, h.why = "paused", "no distances heard (off or out of range)"; T.logLine("GPS: #" .. id .. " paused: " .. h.why) end
            end
        end
        -- mismatches among reporting hosts; blame the PC in most of them, try to re-place it
        for _ = 1, #check do
            local bad = M.mismatches(pos, D, check)
            if #bad == 0 then break end
            local cnt = {}
            for _, b in ipairs(bad) do cnt[b.a] = (cnt[b.a] or 0) + 1; cnt[b.b] = (cnt[b.b] or 0) + 1 end
            local cul, cn = nil, 0
            for id, n in pairs(cnt) do if n > cn or (n == cn and id < cul) then cul, cn = id, n end end
            local others = {}
            for _, id in ipairs(check) do if id ~= cul then others[id] = pos[id] end end
            local np = M.place(cul, others, check, D)
            local h = V.hosts[cul]
            if np then
                pos[cul] = np
                h.x, h.y, h.z, h.st, h.why = np.x, np.y, np.z, "hosting", nil
                T.logLine(string.format("GPS: #%d moved, position updated to %d %d %d", cul, np.x, np.y, np.z))
            else
                local b = bad[1]
                h.st = "paused"
                h.why = string.format("moved? #%d-#%d should be %.1f, is %.1f", b.a, b.b, b.want, b.got)
                T.logLine("GPS: #" .. cul .. " paused: " .. h.why)
                for i, v in ipairs(check) do if v == cul then table.remove(check, i); break end end
                pos[cul] = nil
            end
        end
        -- a paused PC that matches again resumes
        for _, id in ipairs(check) do
            local h = V.hosts[id]
            if h.st == "paused" then
                local others = {}
                for _, o in ipairs(check) do if o ~= id and V.hosts[o].st == "hosting" then others[o] = pos[o] end end
                local p = M.place(id, others, check, D)
                local mine = { x = h.x, y = h.y, z = h.z }
                local okOld = true
                for o, op in pairs(others) do
                    local want = M.d(D, id, o)
                    if want and math.abs(M.dist(mine, op) - want) > M.TOL then okOld = false end
                end
                if okOld and next(others) then
                    h.st, h.why = "hosting", nil
                    T.logLine("GPS: #" .. id .. " resumed")
                elseif p then
                    h.x, h.y, h.z, h.st, h.why = p.x, p.y, p.z, "hosting", nil
                    T.logLine(string.format("GPS: #%d back, position %d %d %d", id, p.x, p.y, p.z))
                end
            end
        end
        -- enough hosts left?
        local active = {}
        for _, id in ipairs(hosts) do if V.hosts[id].st == "hosting" then active[#active + 1] = id end end
        local okSet = #active >= 4
        if okSet then
            local P = M.layout(active, D)
            okSet = P ~= nil
        end
        if not okSet then
            T.logLine("GPS: too few usable hosts, stopped")
            V.hosts, V.st, V.offer, V.asks = {}, "idle", nil, {}
            V.note = "stopped: too few hosts"
            L.lastEval = 0
        end
        publish(t)
    end
end

local function inSetup() return V.st == "setup" or V.st == "asking" end

local function leaderTick(t)
    if not L then newLeaderState(t) end
    local rnd = L.rnd
    if rnd then
        local n = 0
        for _ in pairs(rnd.got) do n = n + 1 end
        if n >= #rnd.expect or t - rnd.at > 9000 then measured(t) end
        return
    end
    if V.st == "idle" or V.st == "offer" then
        if V.never or (V.later and t < V.later) or t < L.nextEval then
            if V.offer then setOffer(nil) end
        elseif L.dirty or t - L.lastEval >= EVAL_MS then
            if #eligible(t) >= 4 then startMeasure(t, "offer") else
                setOffer(nil)
                L.lastEval = t
                L.dirty = false
            end
        end
    elseif V.st == "on" then
        -- a hosting PC went silent: measure now (it will be paused when nobody hears it)
        local live = {}
        for _, id in ipairs(eligible(t)) do live[id] = true end
        for id, h in pairs(V.hosts) do if h.st == "hosting" and not live[id] then L.dirty = true end end
        if L.dirty or t - L.lastMeasure >= G.DRIFT_MS then startMeasure(t, "drift") end
    elseif V.st == "setup" and L.setup and L.setup.phase == "locate" and t - L.setup.at >= 4500 then
        L.setup.phase = "solve"
        for id, p in pairs(L.fixes or {}) do L.known[id] = p end
        for id, p in pairs(sampleKnown(L.setup.ids)) do if not L.known[id] then L.known[id] = p end end
        advance(t)
    end
    if t - lastState >= STATE_MS then publish(t) end
end

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------
local function reply(to, ok, err)
    if to == S.myId then errMsg[S.myId] = err; T.markDirty() return end
    T.send("gps_reply", to, { ok = ok, err = err })
end

local function answer(m, t)
    local rs = L and L.setup
    local ask = V.asks[m.from]
    if not rs or not ask then return reply(m.from, false, "not asked") end
    if ask.kind == "xyz" then
        local x, y, z = tonumber(m.x), tonumber(m.y), tonumber(m.z)
        if not (x and y and z) then return reply(m.from, false, "need three numbers: X Y Z") end
        local p = { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
        local err = M.checkEntry(m.from, p, L.known, rs.D)
        if err then return reply(m.from, false, err) end
        L.known[m.from] = p
    else
        local v = tonumber(m.x)
        if not v then return reply(m.from, false, "need one number") end
        local pick
        for _, c in ipairs(ask.cands) do if math.abs(c[ask.axis] - v) <= M.TOL then pick = c end end
        if not pick then
            return reply(m.from, false, string.format("doesn't match: %s should be %d or %d", ask.axis:upper(),
                ask.cands[1][ask.axis], ask.cands[2][ask.axis]))
        end
        L.known[m.from] = pick
    end
    V.asks[m.from] = nil
    reply(m.from, true)
    local pending = false
    for _ in pairs(V.asks) do pending = true end
    if pending then publish(t) else advance(t) end
end

function handle(m)
    local k, t = m.kind, now()
    if k == "gps_info" then
        local i = info[m.from]
        if not i or i.boot ~= m.boot or t - i.at > INFO_LIVE_MS then
            if L then L.dirty = true end
        end
        info[m.from] = { mk = m.mk, boot = m.boot, at = t }
    elseif k == "gps_state" then
        if T.isLeader() or (T.C and T.C.leader and m.from ~= T.C.leader) then return end
        if (m.rev or 0) == V.rev and V.st == m.st then return end
        V.never, V.st, V.later, V.offer, V.hosts, V.asks = m.never, m.st, m.later, m.offer, m.hosts or {}, m.asks or {}
        V.kinds, V.rev, V.note, V.n = m.kinds or {}, m.rev or 0, m.note, m.n
        save()
        applyHosting()
        T.markDirty()
    elseif k == "gps_reply" then
        if m.to == S.myId or m.to == nil then errMsg[S.myId] = (not m.ok) and m.err or nil; T.markDirty() end
    elseif k == "gps_measure" then
        onMeasure(m.round)
    elseif k == "gps_locate" then
        onLocate(m.round)
    elseif k == "gps_sample" then
        for _, s in ipairs(m.s or {}) do
            if type(s) == "table" and type(s.id) == "number" and type(s.d) == "number" then
                local list = samples[s.id] or {}
                samples[s.id] = list
                list[#list + 1] = { x = s.x, y = s.y, z = s.z, d = s.d }
                while #list > 24 do table.remove(list, 1) end
            end
        end
    elseif not T.isLeader() then
        return
    elseif k == "gps_dist" then
        if L and L.rnd and L.rnd.id == m.round then L.rnd.got[m.from] = m.d or {} end
    elseif k == "gps_fix" then
        if L and L.setup and L.setup.phase == "locate" and m.x then L.fixes[m.from] = { x = m.x, y = m.y, z = m.z } end
    elseif k == "gps_answer" then
        if L then answer(m, t) end
    elseif k == "gps_cmd" then
        if not L then newLeaderState(t) end
        local op = m.op
        if op == "accept" and V.st == "offer" and V.offer then
            beginSetup(t)
        elseif op == "later" then
            V.later = t + LATER_MS
            setOffer(nil)
            publish(t)
        elseif op == "never" then
            V.never = true
            if inSetup() then V.st, V.asks = "idle", {} end
            L.setup = nil
            setOffer(nil)
            publish(t)
        elseif op == "enable" then
            V.never, V.later = false, nil
            V.note = "checking the PCs' layout..."
            L.dirty, L.nextEval = true, 0
            publish(t)
        elseif op == "cancel" and inSetup() then
            L.setup, L.rnd = nil, nil
            V.st, V.asks, V.offer = "idle", {}, nil
            L.nextEval = t + 120000
            publish(t)
        elseif op == "stop" and V.st == "on" then
            V.hosts, V.st = {}, "idle"
            V.note = "stopped by hand"
            L.nextEval = t + 600000
            publish(t)
        end
    end
end

-- From tm_radio: a verified `gps_*` message.
function T.gpsMessage(msg)
    local k = msg.kind
    if k == "gps_state" or k == "gps_info" or k == "gps_measure" or k == "gps_locate" or k == "gps_sample" then
        handle(msg)
    elseif msg.to == S.myId then
        handle(msg)
    end
end

-- ---------------------------------------------------------------------------
-- Tick (wraps T.clusterTick, called by T.tick on every PC whatever its roles)
-- ---------------------------------------------------------------------------
local oldTick = T.clusterTick
function T.clusterTick(tt)
    oldTick(tt)
    if S.mode ~= "server" then return end
    local t = now()
    if lastOpen == 0 then load(); applyHosting() end
    if t - lastOpen >= 10000 then openChannels() end
    if isWireless() and t - lastInfo >= INFO_MS then
        lastInfo = t
        T.send("gps_info", "cluster", { mk = myKind() })
    end
    for i = #jobs, 1, -1 do
        if t >= jobs[i].at then local j = table.remove(jobs, i); pcall(j.fn) end
    end
    if T.isLeader() then leaderTick(t) else L = nil end
end

-- ---------------------------------------------------------------------------
-- Actions from the UI
-- ---------------------------------------------------------------------------
function G.cmd(op) toLeader("gps_cmd", { op = op }) end
function G.answer(x, y, z) toLeader("gps_answer", { x = x, y = y, z = z }) end
function G.myAsk() return V.asks[S.myId] end
function G.err() return errMsg[S.myId] end

-- Coverage estimate from host heights and modem kinds (modem range rule: 64 blocks up to
-- Y 96, rising to 384 at Y 320; ender modems reach anywhere in the dimension).
local function rangeAt(y)
    if y <= 96 then return 64 end
    return math.min(384, 64 + (y - 96) / 224 * 320)
end
-- One short status for footers and the NET page: always shown, so you can tell
-- whether GPS is off for lack of PCs, waiting for you, being set up, or running.
function G.status()
    local t = now()
    local n = #eligible(t)
    local hosts = 0
    for _ in pairs(V.hosts or {}) do hosts = hosts + 1 end
    if V.st == "on" then return "GPS on " .. hosts .. "h", hosts >= 4 end
    if V.st == "offer" then return "GPS? " .. (V.n or n) .. "pc", true end
    if V.st == "asking" then return "GPS F3?", true end
    if V.st == "setup" then return "GPS setup", true end
    if V.never then return "GPS never", false end
    if V.later and t < V.later then return "GPS later", false end
    if n < 4 then return "GPS " .. n .. "/4+pc", false end
    return "GPS layout?", false   -- enough PCs, but too flat/close (see V.note)
end
function G.statusLong()
    local short = G.status()
    local n = #eligible(now())
    local lines = { short }
    if V.st ~= "on" and n < 4 then
        lines[#lines + 1] = n .. " PC(s) with a wireless/ender modem in this cluster; GPS needs 4 or more,"
        lines[#lines + 1] = "spread out and not all at one height."
    end
    if V.note then lines[#lines + 1] = tostring(V.note) end
    return lines
end

function G.coverage()
    local r, ys = {}, {}
    for id, h in pairs(V.hosts) do
        if h.st == "hosting" then
            r[#r + 1] = (V.kinds[id] == "ender") and 1e9 or rangeAt(h.y)
            ys[#ys + 1] = h.y
        end
    end
    table.sort(r, function(a, b) return a > b end)
    table.sort(ys)
    if #r < 4 then return nil end
    local rad = r[4]
    return rad >= 1e8 and "anywhere (ender modems)" or string.format("~%d blocks from the hosts", math.floor(rad)),
        ys[1] .. ".." .. ys[#ys]
end

-- ---------------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------------
local UI = T.ui

local function mine(id) return id == S.myId end

-- Rows used by the banner at the top of the turtle list (after the header).
function T.gpsBanner(ui)
    if not UI or ui.h < 8 then return 0 end
    if V.st == "offer" and V.offer then
        local eligibleHere = ui.side ~= nil
        for _, id in ipairs(V.offer) do if mine(id) then eligibleHere = true end end
        if not eligibleHere then return 0 end
        UI.put(ui, 1, 2, "GPS possible with " .. #V.offer .. " PCs:", colors.yellow)
        local w = math.max(3, math.floor((ui.w - 2) / 3))
        UI.button(ui, 1, 3, w, "Set up", colors.green, function() G.cmd("accept") end)
        UI.button(ui, 1 + w + 1, 3, w, "Later", colors.gray, function() G.cmd("later") end)
        UI.button(ui, 1 + 2 * (w + 1), 3, w, "Never", colors.red, function() G.cmd("never") end)
        return 2
    elseif V.st == "asking" or V.st == "setup" then
        local who = {}
        for id in pairs(V.asks) do who[#who + 1] = "#" .. id end
        table.sort(who)
        UI.put(ui, 1, 2, V.st == "setup" and "GPS: measuring..." or ("GPS setup: waiting for " .. table.concat(who, " ")), colors.yellow)
        return 1
    end
    return 0
end

-- The terminal shows the coordinate prompt on the PC that is asked (until skipped).
function T.gpsPrompt(ui)
    if ui.side ~= nil then return end
    local a = V.asks[S.myId]
    local sig = a and (a.kind .. (a.axis or "") .. V.rev) or nil
    if a and ui.view ~= "gpsask" and ui.gpsSeen ~= (a.kind .. (a.axis or "")) then
        ui.gpsSeen = a.kind .. (a.axis or "")
        ui.view, ui.input = "gpsask", ""
        errMsg[S.myId] = nil
    elseif not a and ui.view == "gpsask" then
        ui.view, ui.input = "list", ""
        ui.gpsSeen = nil
    end
end

function T.gpsKey(ui, e, v)
    if e == "char" and v:match("^[0-9%- %.]$") then
        ui.input = (ui.input or "") .. v
    elseif e == "key" and v == keys.backspace then
        ui.input = (ui.input or ""):sub(1, -2)
    elseif e == "key" and (v == keys.enter or v == keys.numPadEnter) then
        local nums = {}
        for n in (ui.input or ""):gmatch("%S+") do nums[#nums + 1] = tonumber(n) end
        local a = V.asks[S.myId]
        if a and a.kind == "axis" then
            if #nums == 1 and nums[1] then errMsg[S.myId] = nil; G.answer(nums[1]) else errMsg[S.myId] = "type one number" end
        elseif a then
            if #nums == 3 and nums[1] and nums[2] and nums[3] then errMsg[S.myId] = nil; G.answer(nums[1], nums[2], nums[3])
            else errMsg[S.myId] = "type three numbers: X Y Z" end
        end
        ui.input = ""
    end
end

local function renderAsk(ui)
    UI.header(ui, "GPS: this computer", nil, false)
    local a = V.asks[S.myId]
    local lines = {}
    if a and a.kind == "axis" then
        lines[1] = "Look at this computer, press F3 and read Targeted Block. Type its " .. a.axis:upper() .. " only, then Enter."
    else
        lines[1] = "Look at this computer, press F3 and read Targeted Block. Type X Y Z (spaces between), then Enter."
    end
    local y = 2
    for _, l in ipairs(T.wrap(lines[1], ui.w)) do
        if y < ui.h - 3 then UI.put(ui, 1, y, l, colors.white); y = y + 1 end
    end
    UI.put(ui, 1, y, "> " .. (ui.input or "") .. "_", colors.yellow)
    if errMsg[S.myId] then
        for _, l in ipairs(T.wrap(errMsg[S.myId], ui.w)) do
            if y < ui.h - 1 then y = y + 1; UI.put(ui, 1, y, l, colors.red) end
        end
    end
    UI.button(ui, 2, ui.h, math.max(4, math.min(12, ui.w - 2)), "SKIP", colors.gray, function() ui.view = "list" end)
end

local function renderGps(ui)
    UI.header(ui, "GPS", nil, false)
    local L2 = {}
    local function add(s, fg) L2[#L2 + 1] = { s, fg or colors.white } end
    local st = V.st
    if V.never then add("Off: never offer (ENABLE to turn on)", colors.orange)
    elseif st == "on" then add("ON: " .. #hostIds() .. " hosts", colors.lime)
    elseif st == "offer" then add("Possible with " .. tostring(V.n) .. " PCs", colors.yellow)
    elseif st == "asking" or st == "setup" then add("Setting up...", colors.yellow)
    else
        add("Not running" .. ((V.later and now() < V.later) and " (you chose Later; OFFER NOW to ask again)" or ""), colors.lightGray)
        local n = #eligible(now())
        add(n .. " PC(s) with a wireless/ender modem here; needs 4 or more,", n >= 4 and colors.white or colors.orange)
        add("spread out, not all at one height.", colors.lightGray)
    end
    if V.note then
        -- wrap: the reason is the one thing the player needs to read in full
        local line = ""
        for word in tostring(V.note):gmatch("%S+") do
            if #line > 0 and #line + 1 + #word > ui.w then add(line, colors.orange); line = word
            else line = (#line > 0 and (line .. " ") or "") .. word end
        end
        if #line > 0 then add(line, colors.orange) end
    end
    local cov, ys = G.coverage()
    if cov then add("Reach: " .. cov); add("Host heights: Y " .. ys) end
    local mob, ys2 = 0, {}
    for id, r in pairs(S.turtles or {}) do
        if r.st and r.st.gpsHost and r.lastSeen and now() - r.lastSeen < 120000 then
            mob = mob + 1
            if type(r.st.pos) == "table" and mob <= 4 then ys2[#ys2 + 1] = "#" .. id .. " Y" .. tostring(r.st.pos.y) end
        end
    end
    if mob > 0 then add("Mobile hosts heard: " .. mob .. " (" .. table.concat(ys2, " ") .. ")", colors.lightGray) end
    for _, id in ipairs(hostIds()) do
        local h = V.hosts[id]
        add(string.format("#%d %s %d,%d,%d %s%s", id, h.st, h.x, h.y, h.z, V.kinds[id] or "", h.why and (" - " .. h.why) or ""),
            h.st == "hosting" and colors.white or colors.orange)
    end
    for id in pairs(V.asks) do add("waiting for #" .. id, colors.yellow) end
    local defs = {}
    if st == "offer" then defs[#defs + 1] = { "SET UP", colors.green, function() G.cmd("accept") end } end
    if st == "setup" or st == "asking" then defs[#defs + 1] = { "CANCEL", colors.red, function() G.cmd("cancel") end } end
    if st == "on" then defs[#defs + 1] = { "STOP", colors.red, function() G.cmd("stop") end } end
    if V.never then defs[#defs + 1] = { "ENABLE", colors.green, function() G.cmd("enable") end }
    elseif st == "idle" then
        -- after Later (or STOP / CANCEL) the offer is held back for a while: check again now
        defs[#defs + 1] = { "OFFER NOW", colors.green, function() G.cmd("enable") end }
        defs[#defs + 1] = { "NEVER", colors.gray, function() G.cmd("never") end }
    else defs[#defs + 1] = { "NEVER", colors.gray, function() G.cmd("never") end } end
    defs[#defs + 1] = { "BACK", colors.gray, function() ui.view = "net" end }
    local top = UI.buttonGrid(ui, defs, 3, #L2)
    for i, l in ipairs(L2) do
        if 1 + i >= top then break end
        UI.put(ui, 1, 1 + i, l[1], l[2])
    end
end

local function renderCluster(ui)
    UI.header(ui, "Cluster", nil, false)
    local C = T.C or { members = {} }
    local y = 2
    local function line(s, fg) if y < ui.h - 1 then UI.put(ui, 1, y, s, fg or colors.white); y = y + 1 end end
    line("Leader: " .. (C.leader and ("#" .. C.leader) or "none") .. "  me #" .. S.myId .. " " .. tostring(C.role), colors.yellow)
    local ids = { S.myId }
    for id in pairs(C.members) do if id ~= S.myId then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local m = (id == S.myId) and { roles = T.roles, at = now(), role = C.role } or C.members[id]
        local rt = {}
        for _, k in ipairs({ "ui", "gateway", "link", "update", "gps" }) do if m.roles and m.roles[k] then rt[#rt + 1] = k end end
        local live = id == S.myId or T.memberLive(m)
        line(string.format("#%d %s %s%s", id, live and (id == C.leader and "leader" or "up") or "DOWN",
            #rt > 0 and table.concat(rt, ",") or "member", m.label and (" " .. m.label) or ""),
            live and colors.white or colors.red)
    end
    UI.button(ui, 2, ui.h, math.max(4, math.min(12, ui.w - 2)), "BACK", colors.gray, function() ui.view = "net" end)
end

T.VIEWS.gps, T.VIEWS.cluster, T.VIEWS.gpsask = renderGps, renderCluster, renderAsk

return T
