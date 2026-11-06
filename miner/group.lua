-- Version: 1.0.0
-- TurtleMiner army (group) mode, turtle side. See docs/ARMY_PLAN.md "Contracts (batch 0)".
--   group.init(st, cfg, nav, inv, mine, net, ctl)
--   group.active() / group.leaving() / group.wantJoin()
--   group.join(name) -> ok, reason       at the station spot; adopts the station frame as home
--   group.leave()                        asks to leave (finishes the branch first)
--   group.consumeLeft() -> true|false    at home: apply the end of membership, back to the solo home
--   group.nextJob() -> job | nil, waitSec
--   group.enterLane(segs, dir) / group.leaveLane(segs)
--   group.reportDig(pos) / group.jobDone(job, result) / group.shaftDone(result)
-- State lives in st.army = { name, cfg, solo = {home, homeFacing, job, gps}, job, slot, shaft2, leaving, left }.
-- Lane/station hooks are installed on ctl for mine.lua (ctl.lane, ctl.unlane, ctl.station, ctl.unstation, ctl.dig).
-- Without an army none of this is active and solo mining is unchanged.

local group = {}

local st, cfg, nav, inv, mine, net, ctl
local extra, extraN = {}, 0          -- off-grid dug cells since the last claim_done
local doneTries = 0

local function nowMs() return os.epoch("utc") end
local function A() return type(st) == "table" and type(st.army) == "table" and st.army.name and st.army or nil end
local function copyPos(p) return { x = p.x, y = p.y, z = p.z } end
local function save() local ok, state = pcall(require, "state"); if ok and state.save then pcall(state.save, st) end end
local function check()
    if ctl and ctl.check then return ctl.check() end
end

function group.active() return A() ~= nil end
function group.leaving() local a = A(); return a ~= nil and (a.leaving or a.left) and true or false end
function group.settings() local a = A(); return a and a.cfg and a.cfg.settings or {} end

-- The turtle setting GROUP names an army to join when standing at home.
function group.wantJoin()
    local g = cfg and cfg.GROUP
    if type(g) == "string" and g ~= "" and not A() then return g end
    return nil
end

local function applyCfg(c)
    local a = A()
    if not a or type(c) ~= "table" or c.name ~= a.name then return end
    if c.left then a.left = true; save(); return end
    if c.err then return end
    a.cfg = c
    local sh = c.shafts and c.shafts[2]
    if sh and sh.done then a.shaft2 = true end
    if mine and mine.armyInfo then group.syncInfo() end
    save()
end

function group.deepest()
    local a = A()
    local d = st.home.y - 30
    if a and a.cfg then
        d = a.cfg.station and a.cfg.station.y or st.home.y
        for _, lv in ipairs(a.cfg.levels or {}) do if lv.y < d then d = lv.y end end
    end
    return d
end

function group.syncInfo()
    local a = A()
    if not (a and a.cfg and mine) then return end
    local deepest = a.cfg.station and a.cfg.station.y or st.home.y
    for _, lv in ipairs(a.cfg.levels or {}) do if lv.y < deepest then deepest = lv.y end end
    mine.armyInfo({ geom = a.cfg.geom, deepest = deepest })
end

function group.init(st_, cfg_, nav_, inv_, mine_, net_, ctl_)
    st, cfg, nav, inv, mine, net, ctl = st_, cfg_, nav_, inv_, mine_, net_, ctl_
    extra, extraN, doneTries = {}, 0, 0
    if net.onKind then net.onKind("army_cfg", applyCfg) end
    ctl.lane, ctl.unlane = group.enterLane, group.leaveLane
    ctl.station, ctl.unstation = group.stationWait, group.stationRelease
    ctl.dig = group.reportDig
    local a = A()
    mine.armyMode(a ~= nil)
    if a then
        group.syncInfo()
        if a.job then mine.armyJob(a.job) end
    end
end

-- Join ----------------------------------------------------------------------
function group.join(name)
    if A() then return true end
    local pos = st.pos
    local reply = net.request("army_join", { name = name, at = { x = pos.x, y = pos.y, z = pos.z, f = st.facing } },
        "army_cfg", 5)
    if not reply then return false, "no answer from the army server" end
    if reply.err and reply.station and not st.gps then
        -- no GPS: the turtle cannot know world coordinates; it was placed at the station on purpose
        local s = reply.station
        reply = net.request("army_join", { name = name, at = { x = s.x, y = s.y, z = s.z, f = s.f } }, "army_cfg", 5)
        if not reply then return false, "no answer from the army server" end
    end
    if reply.err then return false, tostring(reply.err) end
    if type(reply.station) ~= "table" then return false, "bad army record" end
    local s = reply.station
    local solo = { home = copyPos(st.home), homeFacing = st.homeFacing, job = st.job, gps = st.gps }
    st.army = { name = name, cfg = reply, solo = solo }
    if st.gps and st.facing ~= s.f % 4 and nav.face then nav.face(s.f % 4) end
    st.pos = { x = s.x, y = s.y, z = s.z }
    st.home = copyPos(st.pos)
    st.facing, st.homeFacing = s.f % 4, s.f % 4
    st.job = { corridor = 0, branch = 0, side = "L", step = 0, noGrid = true }
    st.lost, st.facingUnknown, st.facingCands, st.homeMarks = nil, nil, nil, nil
    local okS, state = pcall(require, "state")
    if okS and state.save then pcall(state.save, st, true) end
    mine.armyMode(true)
    group.syncInfo()
    if reply.shafts and reply.shafts[2] and reply.shafts[2].done then st.army.shaft2 = true end
    if net.event then net.event("info", "joined army " .. name) end
    return true
end

function group.leave()
    local a = A()
    if not a or a.leaving then return end
    a.leaving = true
    save()
    net.send("army_leave", "server", { name = a.name })
end

-- At home: when the coordinator has removed us, go back to solo. Returns true when that happened
-- (the caller then walks to the solo home).
function group.consumeLeft()
    local a = A()
    if not a or not (a.leaving or a.left) then return false end
    if not a.left then
        local r = net.request("army_leave", { name = a.name }, "army_cfg", 4)
        if r and r.left then a.left = true end
    end
    if not a.left then return false end
    local solo = a.solo
    st.army = nil
    mine.armyMode(false)
    mine.armyInfo(nil)
    if solo and solo.gps and st.gps and solo.home then
        st.home, st.homeFacing = copyPos(solo.home), solo.homeFacing
    end   -- no GPS: the station stays home (the old relative frame has no meaning here)
    if solo and solo.job then st.job = solo.job else st.job = { corridor = 0, branch = 0, side = "L", step = 0 } end
    st.homeMarks = nil
    local okS, state = pcall(require, "state")
    if okS and state.save then pcall(state.save, st, true) end
    if net.event then net.event("info", "left the army") end
    return true
end

-- Claims ----------------------------------------------------------------------
local function parseKey(key)
    local y, c, b, side = tostring(key):match("^(%-?%d+):(%-?%d+):(%d+):([LR])$")
    if y then return tonumber(y), tonumber(c), tonumber(b), side end
end

local function bookSlot(a, job)
    if net.modemKind and net.modemKind() == "ender" then return end
    -- claimed at depth and still in contact there (a relay reaches the level): live lanes suffice, no slot
    if st.pos.y <= st.home.y - 20 and net.inContact() then return end
    local y, c, b = parseKey(job.key)
    if not y then return end
    local g = job.geom
    local W = 2 * g.bl + g.sp
    local moves = (st.home.y - y) + (2 + (b + 1) * g.sp) + math.abs(c) * W + 2 * g.bl
    local ms = (a.cfg and a.cfg.settings and a.cfg.settings.MS_PER_BLOCK or 700)
    local r = net.request("slot_req", { name = a.name, shaft = a.shaft2 and 2 or 1, dir = "up",
        eta = math.floor(moves * ms * 3) }, "slot", 4)
    if r and r.at then a.slot = { shaft = r.shaft, at = r.at, len = r.len } end
end

local function resendDone(a)
    if a.lastDone and doneTries < 3 then
        doneTries = doneTries + 1
        net.send("claim_done", "server", a.lastDone)
    end
end

function group.nextJob()
    local a = A()
    if not a then return nil, 5 end
    if a.left then return nil, 1 end
    if a.pending then   -- claim_done that could not be sent out of contact
        if net.inContact() then net.send("claim_done", "server", a.pending); a.lastDone, a.pending = a.pending, nil; doneTries = 0; save() end
    end
    if a.cfg and a.cfg.paused and not a.job then return nil, 10 end
    local r = net.request("claim_req", { name = a.name, pos = copyPos(st.pos), fuel = turtle.getFuelLevel() }, "claim", 5)
    if not r then
        if a.job then return a.job end            -- out of contact: keep working the cached claim
        return nil, 5, true                        -- no answer
    end
    if r.dig_shaft then return { dig_shaft = r.dig_shaft } end
    if r.wait then return nil, r.wait end
    if not r.key then return nil, 5 end
    if a.lastDone and a.lastDone.key == r.key then   -- our claim_done was lost: send it again
        resendDone(a)
        return nil, 2
    end
    if type(r.settings) == "table" then
        if r.settings.FUEL_MARGIN then cfg.FUEL_MARGIN = r.settings.FUEL_MARGIN end
        if r.settings.DROP_TRASH ~= nil then cfg.DROP_TRASH = r.settings.DROP_TRASH and true or false end
    end
    local fresh = not (a.job and a.job.key == r.key)
    local job = { key = r.key, level = r.level, geom = r.geom, step = r.step, near = r.near }
    a.job = job
    if fresh then
        a.fuel0 = turtle.getFuelLevel()
        a.lastDone, doneTries = nil, 0
        bookSlot(a, job)
    end
    save()
    return job
end

function group.reportDig(pos)
    if extraN >= 300 or type(pos) ~= "table" then return end
    local k = pos.x .. "," .. pos.y .. "," .. pos.z
    if not extra[k] then extra[k] = true; extraN = extraN + 1 end
end

local function takeExtras()
    local list = {}
    for k in pairs(extra) do list[#list + 1] = k end
    extra, extraN = {}, 0
    return list
end

local function fuelUsed(a)
    local f = turtle.getFuelLevel()
    if type(f) == "number" and type(a.fuel0) == "number" and a.fuel0 > f then return a.fuel0 - f end
    return 0
end

function group.jobDone(job, result)
    local a = A()
    if not a then return end
    local body = { name = a.name, key = job.key, step = job.geom and job.geom.bl or 0,
        ores = result and result.ores or {}, extra = takeExtras(), fuelUsed = fuelUsed(a) }
    a.job, a.slot = nil, nil
    mine.armyJob(nil)
    if net.inContact() then
        net.send("claim_done", "server", body)
        a.lastDone, a.pending = body, nil
    else
        a.pending = body
    end
    doneTries = 0
    save()
end

function group.shaftDone()
    local a = A()
    if not a then return end
    a.shaft2 = true
    net.send("claim_done", "server", { name = a.name, key = "shaft:2", ores = {}, extra = takeExtras(), fuelUsed = 0 })
    save()
end

-- Lanes ----------------------------------------------------------------------
local function sleepCheck(sec)
    for _ = 1, sec do
        sleep(1)
        local c = check()
        if c == "stop" then return "stop" end
    end
end

-- Blocks until every segment is granted (all or nothing), or an out-of-contact up trip reaches its
-- slot time. Returns true | false, reason ("stop" | "use_shaft2" | "denied").
function group.enterLane(segs, dir, yield)
    local a = A()
    if not a or #segs == 0 then return true end
    local started = nowMs()
    while true do
        local c = check()
        if c == "stop" then return false, "stop" end
        if a.left then return true end   -- removed from the army: nobody answers, nobody expects us
        local r
        if net.inContact() then r = net.request("seg_req", { name = a.name, segs = segs, dir = dir }, "seg_grant", 4) end
        if r and r.segs then
            return true
        end
        if r and r.why == "use_shaft2" then return false, "use_shaft2" end
        if r and r.wait then
            -- refused because an out-of-contact climber may be in the shaft: give the station spot back
            -- (the hook steps aside and leaves the queue) so the climber is not blocked behind us
            if yield and (r.why == "slot_window" or r.why == "climber_waiting") then local y = yield; yield = nil; pcall(y) end
            if sleepCheck(math.min(tonumber(r.wait) or 5, 5)) == "stop" then return false, "stop" end
        elseif dir == "up" then
            -- nobody answered (out of contact): the booked slot window, else keep trying a while and go anyway
            local sl = a.slot
            if sl and nowMs() < sl.at + sl.len then
                if nowMs() >= sl.at then return true end
                if sleepCheck(1) == "stop" then return false, "stop" end
            else
                if nowMs() - started > 40000 + (os.getComputerID() % 7) * 25000 then return true end   -- spread the stragglers
                if sleepCheck(3) == "stop" then return false, "stop" end
            end
        else
            if sleepCheck(3) == "stop" then return false, "stop" end
        end
    end
end

function group.leaveLane(segs)
    local a = A()
    if a and #segs > 0 and net.online() then net.send("seg_release", "server", { name = a.name, segs = segs }) end
end

-- Station queue: one turtle at the station spot at a time. A single try: true = go (or nobody answers).
local function stationTry(a, climb)
    if a.left or not net.inContact() then return true end
    local r = net.request("seg_req", { name = a.name, segs = { "station" }, dir = "up", climb = climb and true or nil }, "station_q", 4)
    if not r then return true end
    return r.go and true or false
end

-- Wait for our turn: at depth (before the up lane) and just below the top cell (climb = true: a climber is due).
function group.stationWait(climb)
    local a = A()
    if not a then return end
    local t0 = nowMs()
    while nowMs() - t0 < 600000 and not stationTry(a, climb) do
        if sleepCheck(3) == "stop" then return end
    end
end

function group.stationRelease()
    local a = A()
    if a and net.online() then net.send("seg_release", "server", { name = a.name, segs = { "station" } }) end
end

function group.status()
    local a = A()
    if not a then return nil end
    return { name = a.name, key = a.job and a.job.key, leaving = a.leaving and true or nil }
end

return group
