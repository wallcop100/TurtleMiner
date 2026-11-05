-- Version: 1.0.0
-- TurtleMiner army coordinator (docs/ARMY_PLAN.md, contracts batch 0). Runs on the cluster LEADER only.
-- Pure functions at the top (no radio, no clock: pass `now`), message handlers below.
-- Records live in S.armies[name] and replicate with the rest of the database.
-- Extra kinds beyond the plan: seg_req with segs={"station"} joins the station queue (answered with
-- station_q; seg_release {"station"} leaves it); claim_done with key "shaft:2" reports the second shaft dug.
local T = ...
local S = T.S
local A = {}
T.army = A

A.KINDS = { army_new = true, army_set = true, army_join = true, army_leave = true, army_release = true,
    claim_req = true, claim_done = true, seg_req = true, seg_release = true, slot_req = true }
T.armyKinds = A.KINDS

S.armies = S.armies or {}
S.dA = S.dA or {}

local PRESETS = { diamond = -58, redstone = -58, lapis = 0, gold = -16, iron = 16, copper = 48, coal = 96,
    emerald = 232, ancient_debris = 15 }
A.PRESETS = PRESETS
local MERGE = 4
local DEFAULT_GEOM = { bl = 32, sp = 3, ml = 64 }
local DEFAULT_SETTINGS = { FUEL_MARGIN = 100, DROP_TRASH = true, SHAFT_WAIT_S = 60, SEG_LEN = 16,
    MS_PER_BLOCK = 700, SLOT_MARGIN_MS = 10000, NEAR = 3, MAX_CONVOY_MS = 120000 }
local OPPOSITE = { down = "up", up = "down", ["in"] = "out", out = "in" }
local DVEC = { [0] = { 0, -1 }, [1] = { 1, 0 }, [2] = { 0, 1 }, [3] = { -1, 0 } }
local WAIT_SEC = 5

local function isInt(n) return type(n) == "number" and n == math.floor(n) end

-- ---------------------------------------------------------------------------
-- Pure: frame, levels, branches
-- ---------------------------------------------------------------------------
function A.toWorld(station, f, r, y)
    local F, R = DVEC[station.f % 4], DVEC[(station.f + 1) % 4]
    return { x = station.x + f * F[1] + r * R[1], y = y, z = station.z + f * F[2] + r * R[2] }
end

-- Ore ids -> levels {{y, focus}} sorted deep to shallow; closer than 4 blocks merge; levels at or above
-- the station are dropped. targetY (optional) adds a level with no focus.
function A.levelsFor(ores, targetY, stationY)
    local raw = {}
    for _, o in ipairs(ores or {}) do
        local y = PRESETS[o]
        if y then raw[#raw + 1] = { y = y, ore = o } end
    end
    if targetY then raw[#raw + 1] = { y = targetY } end
    table.sort(raw, function(a, b) if a.y ~= b.y then return a.y < b.y end return (a.ore or "") < (b.ore or "") end)
    local levels = {}
    for _, e in ipairs(raw) do
        if not stationY or e.y < stationY then
            local last = levels[#levels]
            if last and e.y - last.y < MERGE then
                if e.ore then last.focus[#last.focus + 1] = e.ore end
            else
                levels[#levels + 1] = { y = e.y, focus = e.ore and { e.ore } or {} }
            end
        end
    end
    return levels
end

function A.width(g) return 2 * g.bl + g.sp end
function A.branchF(g, b) return 2 + (b + 1) * g.sp end
function A.branchesPerCorridor(g)
    local n = 0
    while A.branchF(g, n) <= 1 + g.ml do n = n + 1 end
    return n
end
function A.branchKey(y, c, b, side) return y .. ":" .. c .. ":" .. b .. ":" .. side end
function A.parseKey(key)
    local y, c, b, side = tostring(key):match("^(%-?%d+):(%-?%d+):(%d+):([LR])$")
    if not y then return nil end
    return tonumber(y), tonumber(c), tonumber(b), side
end

-- Walking cost from the station spot to the start of a branch: shaft down, spine to the corridor (both
-- directions, |c|), main to the branch row. Deeper levels and far corridors cost more.
function A.cost(army, y, c, b)
    local g = army.geom
    return (army.station.y - y) + math.abs(c) * A.width(g) + (A.branchF(g, b) - 2)
end

-- World bounding box of a branch: used for `near` extra digs.
function A.branchBox(army, y, c, b, side)
    local g = army.geom
    local f, r0 = A.branchF(g, b), c * A.width(g)
    local r1 = side == "R" and r0 + g.bl or r0 - g.bl
    local p, q = A.toWorld(army.station, f, r0, y), A.toWorld(army.station, f, r1, y)
    return { x1 = math.min(p.x, q.x), x2 = math.max(p.x, q.x), z1 = math.min(p.z, q.z), z2 = math.max(p.z, q.z), y = y }
end

local function corridorAt(i) -- 0, 1, -1, 2, -2, ...
    if i == 0 then return 0 end
    local k = math.floor((i + 1) / 2)
    return (i % 2 == 1) and k or -k
end

-- Nearest free branch over all levels. Ever-growing: corridors are visited in order of distance until no
-- farther corridor can beat the best found. Returns {key,y,c,b,side,cost,level} or nil.
function A.nextBranch(army)
    local g, nb = army.geom, A.branchesPerCorridor(army.geom)
    if nb < 1 or #army.levels == 0 then return nil end
    local best
    for _, lv in ipairs(army.levels) do
        for i = 0, 4000 do
            local c = corridorAt(i)
            local base = (army.station.y - lv.y) + math.abs(c) * A.width(g)
            if best and base >= best.cost then break end
            for b = 0, nb - 1 do
                local found = false
                for _, side in ipairs({ "R", "L" }) do
                    local key = A.branchKey(lv.y, c, b, side)
                    if not army.branches[key] then
                        local cost = A.cost(army, lv.y, c, b) + (side == "L" and 0.1 or 0)
                        if not best or cost < best.cost then
                            best = { key = key, y = lv.y, c = c, b = b, side = side, cost = cost, level = lv }
                        end
                        found = true
                        break
                    end
                end
                if found then break end  -- later b only cost more
            end
        end
    end
    return best
end

-- Extra digs (world "x,y,z") within `d` blocks of the branch.
function A.nearExtras(army, y, c, b, side, d)
    local box, out = A.branchBox(army, y, c, b, side), {}
    for k in pairs(army.extra) do
        local x, yy, z = k:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
        x, yy, z = tonumber(x), tonumber(yy), tonumber(z)
        if x and math.abs(yy - y) <= d and x >= box.x1 - d and x <= box.x2 + d and z >= box.z1 - d and z <= box.z2 + d then
            out[#out + 1] = k
            if #out >= 300 then break end
        end
    end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- Pure: segment locks (convoys)
-- ---------------------------------------------------------------------------
-- Grant all of `keys` for `tid` going `dir`, or none. Returns true | false, reason.
function A.segGrant(army, tid, keys, dir, now)
    local cfg = army.settings
    for _, key in ipairs(keys) do
        local s = army.segs[key]
        if key:match("^s1:") and dir == "up" and army.shafts[2] and army.shafts[2].done then return false, "use_shaft2" end
        if key:match("^s2:") and dir == "down" then return false, "shaft2_up_only" end
        local k = dir == "down" and key:match("^s(%d):")
        if k then   -- a turtle out of contact comes up on its booked window without a lock: keep the shaft free
            for _, sl in ipairs(army.slots) do
                if sl.tid ~= tid and tostring(sl.shaft) == k and now > sl.at - sl.len and now < sl.at + sl.len then
                    return false, "slot_window"
                end
            end
        end
        if s and next(s.holders) then
            local others = 0
            for id in pairs(s.holders) do if id ~= tid then others = others + 1 end end
            if others > 0 then
                if s.dir ~= dir then return false, "opposite" end
                local w = s.want and s.want[OPPOSITE[dir]]
                -- a convoy that has run long gives way once the other direction has waited
                if not s.holders[tid] and w and now - w < 60000 and now - (s.since or now) > cfg.MAX_CONVOY_MS then
                    return false, "convoy_full"
                end
            end
        end
    end
    for _, key in ipairs(keys) do
        local s = army.segs[key]
        if not s then s = { holders = {} }; army.segs[key] = s end
        if not next(s.holders) or s.dir ~= dir then s.dir, s.since, s.want = dir, now, nil end
        s.holders[tid] = now
    end
    return true
end

function A.segWant(army, keys, dir, now)
    for _, key in ipairs(keys) do
        local s = army.segs[key]
        if s then s.want = s.want or {}; s.want[dir] = now end
    end
end

function A.segRelease(army, tid, keys)
    for _, key in ipairs(keys) do
        local s = army.segs[key]
        if s then
            s.holders[tid] = nil
            if not next(s.holders) then army.segs[key] = nil end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Pure: timed slots for turtles out of contact (up trips)
-- ---------------------------------------------------------------------------
function A.deepest(army)
    local d = army.station.y
    for _, lv in ipairs(army.levels) do if lv.y < d then d = lv.y end end
    return d
end

function A.slotLen(army)
    local s = army.settings
    return (army.station.y - A.deepest(army)) * s.MS_PER_BLOCK + s.SLOT_MARGIN_MS
end

-- Book the first window on `shaft` starting at or after now+eta that overlaps no other slot.
function A.bookSlot(army, tid, shaft, dir, eta, now)
    local keep = {}
    for _, sl in ipairs(army.slots) do
        if sl.tid ~= tid and sl.at + sl.len > now - 60000 then keep[#keep + 1] = sl end
    end
    local len, at = A.slotLen(army), now + math.max(0, eta or 0)
    table.sort(keep, function(a, b) return a.at < b.at end)
    for _, sl in ipairs(keep) do
        if sl.shaft == shaft and at < sl.at + sl.len and sl.at < at + len then at = sl.at + sl.len end
    end
    local slot = { tid = tid, shaft = shaft, dir = dir, at = at, len = len }
    keep[#keep + 1] = slot
    army.slots = keep
    return slot
end

-- ---------------------------------------------------------------------------
-- Pure: shaft wait average, station queue, release
-- ---------------------------------------------------------------------------
function A.noteWait(army, ms)
    local w = army.wait
    local n = math.min(w.n, 9)
    w.avgMs = (w.avgMs * n + ms) / (n + 1)
    w.n = w.n + 1
end

function A.wantSecondShaft(army)
    local s2 = army.shafts[2]
    return s2 and not s2.done and not s2.digger and army.wait.n >= 3
        and army.wait.avgMs >= army.settings.SHAFT_WAIT_S * 1000
end

function A.queueAdd(army, tid)
    for i, id in ipairs(army.queue) do if id == tid then return i end end
    army.queue[#army.queue + 1] = tid
    return #army.queue
end
function A.queueRemove(army, tid)
    for i, id in ipairs(army.queue) do if id == tid then table.remove(army.queue, i); return end end
end

-- Free everything a turtle holds (army_release). Returns how many things were freed.
function A.releaseTurtle(army, tid)
    local n = 0
    for key, b in pairs(army.branches) do
        if b.state == "claimed" and b.tid == tid then army.branches[key] = nil; n = n + 1 end
    end
    for key, s in pairs(army.segs) do
        if s.holders[tid] then s.holders[tid] = nil; n = n + 1 end
        if not next(s.holders) then army.segs[key] = nil end
    end
    local keep = {}
    for _, sl in ipairs(army.slots) do if sl.tid ~= tid then keep[#keep + 1] = sl end end
    army.slots = keep
    A.queueRemove(army, tid)
    if army.shafts[2] and army.shafts[2].digger == tid then army.shafts[2].digger = nil end
    army.waiting[tid] = nil
    return n
end

function A.claimOf(army, tid)
    for key, b in pairs(army.branches) do
        if b.state == "claimed" and b.tid == tid then return key, b end
    end
end

function A.addExtras(army, list, now)
    local n = 0
    if type(list) ~= "table" then return 0 end
    for _, k in ipairs(list) do
        if type(k) == "string" and k:match("^%-?%d+,%-?%d+,%-?%d+$") and not army.extra[k] then army.extra[k] = now; n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------
function A.newRecord(name, station, levels)
    local st = {}
    for k, v in pairs(DEFAULT_SETTINGS) do st[k] = v end
    return { name = name, station = station, levels = levels,
        geom = { bl = DEFAULT_GEOM.bl, sp = DEFAULT_GEOM.sp, ml = DEFAULT_GEOM.ml },
        settings = st, shafts = { { k = 1, done = true }, { k = 2, done = false } }, members = {}, branches = {}, extra = {},
        segs = {}, slots = {}, queue = {}, stats = { ores = {}, branchesDone = 0, startedAt = 0, fuelUsed = 0 },
        paused = false, wait = { avgMs = 0, n = 0 }, waiting = {} }
end

local function touch(army) S.dA[army.name] = true; army.ver = (army.ver or 0) + 1 end

function A.save()
    if T.writeAtomic then pcall(T.writeAtomic, "miner_armies.db", textutils.serialize(S.armies)) end
end
function A.load()
    local t = T.readFile and T.readFile("miner_armies.db")
    t = t and textutils.unserialize(t)
    if type(t) == "table" then S.armies = t end
end

local function sendTo(kind, to, body)
    if A.out then return A.out(kind, to, body) end   -- tests may capture
    return T.send(kind, to, body)
end

-- What a member needs: the record minus branches/extra/segs/slots.
function A.cfgOf(army)
    local c = {}
    for k, v in pairs(army) do
        if k ~= "branches" and k ~= "extra" and k ~= "segs" and k ~= "slots" and k ~= "waiting" then c[k] = v end
    end
    return c
end

function A.new(name, station, ores, targetY, now)
    if type(name) ~= "string" or name == "" then return nil, "name" end
    if S.armies[name] then return nil, "exists" end
    if type(station) ~= "table" or not (isInt(station.x) and isInt(station.y) and isInt(station.z) and isInt(station.f)) then
        return nil, "station must be integers x y z f"
    end
    station = { x = station.x, y = station.y, z = station.z, f = station.f % 4 }
    local levels = A.levelsFor(ores, targetY, station.y)
    if #levels == 0 then return nil, "no level below the station" end
    local army = A.newRecord(name, station, levels)
    army.stats.startedAt = now or T.now()
    S.armies[name] = army
    touch(army)
    return army
end

local function memberOf(tid)
    for _, army in pairs(S.armies) do if army.members[tid] then return army end end
end
A.memberOf = memberOf

local function sendCfg(army, tid, extra)
    local c = A.cfgOf(army)
    for k, v in pairs(extra or {}) do c[k] = v end
    sendTo("army_cfg", tid, c)
end

local function armyFor(msg) return S.armies[msg.name] or memberOf(msg.from) end

-- ---------------------------------------------------------------------------
-- Handlers (leader only)
-- ---------------------------------------------------------------------------
local H = {}

function H.army_new(msg, now)
    local a, err = A.new(msg.name, msg.station, msg.ores, msg.targetY, now)
    if a then A.save() end
    return a, err
end

function H.army_set(msg, now)
    local army = S.armies[msg.name]
    if not army then return nil, "unknown army" end
    local k, v = msg.key, msg.value
    if k == "paused" then army.paused = v and true or false
    elseif k == "level_add" and isInt(v) and v < army.station.y then
        for _, lv in ipairs(army.levels) do if math.abs(lv.y - v) < MERGE then return nil, "level too close" end end
        army.levels[#army.levels + 1] = { y = v, focus = {} }
        table.sort(army.levels, function(a, b) return a.y < b.y end)
    elseif k == "level_remove" and isInt(v) then
        for i, lv in ipairs(army.levels) do if lv.y == v then table.remove(army.levels, i); break end end
    elseif type(k) == "string" and k:sub(1, 5) == "geom." and army.geom[k:sub(6)] and isInt(v) and v > 0 then
        if next(army.branches) then return nil, "geometry is fixed once branches exist" end
        army.geom[k:sub(6)] = v
    elseif type(k) == "string" and k ~= "" and k:sub(1, 5) ~= "geom." then army.settings[k] = v
    else return nil, "bad key" end
    touch(army); A.save()
    for tid in pairs(army.members) do sendCfg(army, tid) end
    return army
end

function H.army_join(msg, now)
    local army = S.armies[msg.name]
    if not army then sendTo("army_cfg", msg.from, { name = tostring(msg.name), err = "unknown army" }); return nil, "unknown army" end
    local at, st = msg.at, army.station
    if type(at) ~= "table" or at.x ~= st.x or at.y ~= st.y or at.z ~= st.z then
        sendCfg(army, msg.from, { err = "not at the station spot" })
        return nil, "not at the station spot"
    end
    army.members[msg.from] = { joined = now, state = "work" }
    touch(army); A.save()
    sendCfg(army, msg.from)
    return army
end

local function removeMember(army, tid)
    A.releaseTurtle(army, tid)
    army.members[tid] = nil
    touch(army); A.save()
    sendCfg(army, tid, { left = true })
end

function H.army_leave(msg, now)
    local army = armyFor(msg)
    if not army or not army.members[msg.from] then return nil, "not a member" end
    if A.claimOf(army, msg.from) then
        army.members[msg.from].state = "leaving"
        touch(army)
    else
        removeMember(army, msg.from)
    end
    return army
end

function H.army_release(msg, now)
    local army = S.armies[msg.name]
    if not army then return nil, "unknown army" end
    local n = A.releaseTurtle(army, msg.tid)
    touch(army); A.save()
    return army, n
end

local function claimBody(army, key, b)
    local y, c, bi, side = A.parseKey(key)
    local lv
    for _, l in ipairs(army.levels) do if l.y == y then lv = l end end
    return { key = key, level = lv or { y = y, focus = {} }, geom = army.geom, step = b.step or 0,
        near = A.nearExtras(army, y, c, bi, side, army.settings.NEAR), settings = army.settings }
end

function H.claim_req(msg, now)
    local army = armyFor(msg)
    local tid = msg.from
    if not army or not army.members[tid] then return nil, "not a member" end
    local m = army.members[tid]
    if m.state == "leaving" and not A.claimOf(army, tid) then removeMember(army, tid); return army, "left" end
    local function reply(body) sendTo("claim", tid, body); return army, body end
    local key, b = A.claimOf(army, tid)
    if key then return reply(claimBody(army, key, b)) end   -- never reassign: same holder, same branch
    if army.paused or m.state == "leaving" then return reply({ wait = 30 }) end
    if A.wantSecondShaft(army) then
        army.shafts[2].digger = tid
        touch(army)
        return reply({ dig_shaft = 2 })
    end
    local nb = A.nextBranch(army)
    if not nb then return reply({ wait = 60 }) end
    local rec = { state = "claimed", tid = tid, since = now, step = 0 }
    army.branches[nb.key] = rec
    touch(army); A.save()
    return reply(claimBody(army, nb.key, rec))
end

function H.claim_done(msg, now)
    local army = armyFor(msg)
    local tid = msg.from
    if not army or not army.members[tid] then return nil, "not a member" end
    A.addExtras(army, msg.extra, now)
    if type(msg.ores) == "table" then
        for fam, n in pairs(msg.ores) do
            if type(n) == "number" then army.stats.ores[fam] = (army.stats.ores[fam] or 0) + n end
        end
    end
    army.stats.fuelUsed = army.stats.fuelUsed + (tonumber(msg.fuelUsed) or 0)
    if msg.key == "shaft:2" then
        army.shafts[2].done, army.shafts[2].digger = true, nil
    else
        local b = army.branches[msg.key]
        if b and b.tid == tid then
            b.state, b.step, b.since, b.tid = "done", tonumber(msg.step) or b.step, now, nil
            army.stats.branchesDone = army.stats.branchesDone + 1
        end
    end
    if army.members[tid].state == "leaving" and not A.claimOf(army, tid) then
        removeMember(army, tid)
    else
        touch(army); A.save()
    end
    return army
end

function H.seg_req(msg, now)
    local army = armyFor(msg)
    local tid = msg.from
    if not army or not army.members[tid] then return nil, "not a member" end
    local keys = type(msg.segs) == "table" and msg.segs or {}
    if keys[1] == "station" then
        local pos = A.queueAdd(army, tid)
        touch(army)
        sendTo("station_q", tid, { pos = pos, go = pos == 1 })
        return army, pos
    end
    local ok, why = A.segGrant(army, tid, keys, msg.dir, now)
    if not ok then
        army.waiting[tid] = army.waiting[tid] or now
        A.segWant(army, keys, msg.dir, now)
        sendTo("seg_grant", tid, { wait = WAIT_SEC, why = why })
        touch(army)
        return army, why
    end
    local w = army.waiting[tid]
    army.waiting[tid] = nil
    for _, k in ipairs(keys) do
        if k:match("^s%d:") then A.noteWait(army, w and now - w or 0); break end
    end
    touch(army)
    sendTo("seg_grant", tid, { segs = keys })
    return army, true
end

function H.seg_release(msg, now)
    local army = armyFor(msg)
    local tid = msg.from
    if not army then return nil, "not a member" end
    local keys = type(msg.segs) == "table" and msg.segs or {}
    if keys[1] == "station" then
        A.queueRemove(army, tid)
        if army.queue[1] then sendTo("station_q", army.queue[1], { pos = 1, go = true }) end
    else
        A.segRelease(army, tid, keys)
    end
    touch(army)
    return army
end

function H.slot_req(msg, now)
    local army = armyFor(msg)
    if not army or not army.members[msg.from] then return nil, "not a member" end
    local slot = A.bookSlot(army, msg.from, tonumber(msg.shaft) or 1, msg.dir or "up", tonumber(msg.eta) or 0, now)
    touch(army)
    sendTo("slot", msg.from, { shaft = slot.shaft, at = slot.at, len = slot.len })
    return army, slot
end

-- Entry point (tm_radio, and tests): leader only. Returns army, extra (for tests).
function A.handle(msg, now)
    if T.isLeader and not T.isLeader() then return end
    local h = H[msg.kind]
    if not h then return end
    now = now or T.now()
    local r = T.getRec and T.getRec(msg.from, false)
    if r then r.lastSeen = now end
    local ok, a, b = pcall(h, msg, now)
    if not ok then
        if T.logLine then T.logLine("army: " .. msg.kind .. " failed: " .. tostring(a)) end
        return nil, tostring(a)
    end
    return a, b
end

-- Catchup / status carry extra digs: add them to the army the turtle belongs to.
function A.onExtras(tid, list, now)
    local army = memberOf(tid)
    if army and A.addExtras(army, list, now or T.now()) > 0 then touch(army) end
end

-- Replication (tm_db).
function A.takeDelta()
    local d, any = {}, false
    for name in pairs(S.dA) do d[name] = S.armies[name] or false; any = true end
    S.dA = {}
    return any and d or nil
end
function A.applySnapshot(armies) S.armies = type(armies) == "table" and armies or {}; S.dA = {}; A.save() end
function A.applyDelta(d)
    for name, a in pairs(type(d) == "table" and d or {}) do S.armies[name] = a or nil end
    A.save()
end

return A
