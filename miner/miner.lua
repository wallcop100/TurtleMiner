-- Version: 1.6.0
-- TurtleMiner main program. Two coroutines only:
--   worker : the only code that moves the turtle (state machine over st.phase)
--   net.run: receives commands, acks them, sends status
-- Never prompts. Problems end in NEEDS_HELP with a reason, never in read().

-- The version is the first line of this file, so it can never go stale.
local function readVersion()
    local ok, v = pcall(function()
        for _, name in ipairs({ "miner.lua", "miner" }) do
            if fs.exists(name) then
                local h = fs.open(name, "r")
                if h then
                    local line = h.readLine()
                    h.close()
                    local ver = line and string.match(line, "^%-%-%s*Version:%s*([%w%.%-]+)")
                    if ver then return ver end
                end
            end
        end
    end)
    return ok and v or nil
end
local VERSION = readVersion() or "?"

local config = require("config")
local state  = require("state")
local nav    = require("nav")
local inv    = require("inv")
local mine   = require("mine")
local net    = require("net")
local okG, group = pcall(require, "group")
if not okG then group = nil end

local function noGroup() return false end
if not group then
    group = { active = noGroup, leaving = noGroup, wantJoin = function() return nil end, consumeLeft = noGroup,
        init = function() end, status = function() return nil end, settings = function() return {} end }
end
local cfg = config.load()
local st            -- state table, shared by reference with nav/inv/mine
local booted = false
local ctl = {}

local WORK = { TO_WORK = true, MINING = true, VEIN = true }
local UNSET_Y = -9999
local NEED_HOME_Y = "no GPS: set HOME_Y to this turtle's Y level (SET HOME_Y), then RESUME"
local LOST_FAR    = "state lost: send RESET_HOME here or carry to home"
local STUCK_RETRIES = 5        -- automatic retries after a "stuck" NEEDS_HELP
local NEAR_HOME   = 3          -- blocks: GPS position close enough to adopt a server home record

-- Runtime control requests (set by commands, consumed by the worker).
local req = { ret = false, pause = false, resume = false, homeReset = false }
local helpRetry      = nil    -- fn() -> nextPhase, reason | nil  (NEEDS_HELP auto retry)
local lastPhase      = nil
local homeScanned    = false
-- Fuel at program start; consumed by the first REFUELING that is still at the boot home.
local bootFuel       = turtle.getFuelLevel()
local homeOverhead   = 0      -- fuel spent at home after boot (facing calibration) before leaving
local noRetreat      = false  -- next goHome skips mine.retreat (home adopted from the server, no tunnels known)
local homeOrder      = nil    -- next goHome's nav.goTo axis order (after surfacing: "xzy")

-- Screen ---------------------------------------------------------------------
-- The turtle's own terminal (39x13): a fixed status block on top (phase, reason, position,
-- fuel, job, ores), log lines scroll in a window below it. print() is redirected into that
-- window, so nothing scrolls the status away. Redrawn on every phase change and every
-- SCREEN_EVERY seconds. Falls back to plain printing when the screen is too small or the
-- window API is missing.

local SCREEN_EVERY = 10
local STATUS_ROWS = 5           -- 4 status lines + 1 separator
local screen = nil              -- { win = status window, w = width } when active

local function setupScreen()
    if not (term and term.current and window and window.create) then return end
    local ok = pcall(function()
        local parent = term.current()
        local w, h = parent.getSize()
        if w < 20 or h < STATUS_ROWS + 3 then return end
        parent.clear()
        local top = window.create(parent, 1, 1, w, STATUS_ROWS)
        local logWin = window.create(parent, 1, STATUS_ROWS + 1, w, h - STATUS_ROWS)
        logWin.setCursorPos(1, 1)
        term.redirect(logWin)
        screen = { win = top, w = w }
    end)
    if not ok then screen = nil end
end

local function fit(text, w)
    text = tostring(text or "")
    if #text > w then return string.sub(text, 1, w) end
    return text .. string.rep(" ", w - #text)
end

local function drawStatus()
    if not screen then return end
    pcall(function()
        local win, w = screen.win, screen.w
        local s = st
        local fuel = turtle.getFuelLevel()
        local lines = {}
        local label = os.getComputerLabel() or ("miner-" .. os.getComputerID())
        local phase = s and s.phase or "BOOT"
        lines[1] = phase .. string.rep(" ", math.max(1, w - #phase - #label)) .. label
        lines[2] = (s and s.reason) and tostring(s.reason) or ""
        if s and type(s.pos) == "table" then
            lines[3] = "pos " .. s.pos.x .. "," .. s.pos.y .. "," .. s.pos.z .. " f" .. tostring(s.facing)
                .. (s.lost and " LOST" or "") .. "  fuel " .. tostring(fuel)
            local j = type(s.job) == "table" and s.job or {}
            local ores = type(s.stats) == "table" and s.stats.ores or 0
            lines[4] = "job c" .. tostring(j.corridor or 0) .. " b" .. tostring(j.branch or 0)
                .. tostring(j.side or "L") .. " s" .. tostring(j.step or 0) .. "  ores " .. tostring(ores)
        else
            lines[3] = "fuel " .. tostring(fuel)
            lines[4] = ""
        end
        lines[5] = string.rep("-", w - 18) .. " keys: R P B S H J ?"
        if win.isColor and win.isColor() and colors then
            win.setTextColor(phase == "NEEDS_HELP" and colors.red or colors.yellow)
        end
        for i = 1, STATUS_ROWS do
            win.setCursorPos(1, i)
            if i == 2 and colors and win.isColor and win.isColor() then win.setTextColor(colors.white) end
            win.write(fit(lines[i], w))
        end
        if colors and win.isColor and win.isColor() then win.setTextColor(colors.white) end
    end)
end

local function screenLoop()
    while true do
        sleep(SCREEN_EVERY)
        drawStatus()
    end
end

-- Helpers --------------------------------------------------------------------

local function log(text)
    if print then pcall(print, text) end
end

local function copyPos(p)
    if type(p) ~= "table" then return { x = 0, y = 0, z = 0 } end
    return { x = math.floor(p.x or 0), y = math.floor(p.y or 0), z = math.floor(p.z or 0) }
end

local function samePos(a, b)
    return type(a) == "table" and type(b) == "table"
        and a.x == b.x and a.y == b.y and a.z == b.z
end

local function atHome() return st ~= nil and samePos(st.pos, st.home) end

-- GPS position p close enough to home record h to walk there safely: in its column
-- (shaft) or within NEAR_HOME blocks on every axis.
local function nearHome(p, h)
    local dx, dy, dz = math.abs(p.x - h.x), math.abs(p.y - h.y), math.abs(p.z - h.z)
    if dx == 0 and dz == 0 then return true end
    return dx <= NEAR_HOME and dz <= NEAR_HOME and dy <= NEAR_HOME
end

local function freshJob() return { corridor = 0, branch = 0, side = "L", step = 0 } end

local function fuelLevel()
    local f = turtle.getFuelLevel()
    if f == "unlimited" then return math.huge end
    return f
end

local function firstLine(s)
    s = tostring(s)
    return string.sub(string.match(s, "^[^\n]*") or s, 1, 120)
end

local function yield()
    os.queueEvent("tminer_yield")
    os.pullEvent("tminer_yield")
end

local function normalize(t)
    t.pos = copyPos(t.pos); t.home = copyPos(t.home)
    t.facing = math.floor(tonumber(t.facing) or 0) % 4
    t.homeFacing = math.floor(tonumber(t.homeFacing) or 0) % 4
    t.flags = type(t.flags) == "table" and t.flags or {}
    t.stats = type(t.stats) == "table" and t.stats or {}
    t.stats.ores = t.stats.ores or 0
    t.stats.blocks = t.stats.blocks or 0
    t.stats.trips = t.stats.trips or 0
    t.stats.started = t.stats.started or os.epoch("utc")
    t.job = type(t.job) == "table" and t.job or freshJob()
end

local function save() return state.save(st) end

-- Trips and ETA (docs/COMMS.md rule 3) ------------------------------------------
-- Before leaving home the turtle sends `away` with an ETA so the monitor expects the silence
-- of a basic-modem turtle at depth. The estimate uses the job size, its own measured trip times
-- (running averages in st.stats: moveSec = seconds per fuel unit, tripSec = full trips) and fuel.

local DEFAULT_MOVE_SEC = 1.5   -- s per move (dig + inspect + move) until a trip was measured
local MIN_TRIP_SEC     = 60

local function remainingMoves()
    if group.active() then return 4 * (tonumber(cfg.BRANCH_LENGTH) or 32) end
    local g = type(st.job) == "table" and type(st.job.geom) == "table" and st.job.geom or {}
    local bl = tonumber(g.bl) or cfg.BRANCH_LENGTH or 32
    local sp = tonumber(g.sp) or cfg.BRANCH_SPACING or 3
    local ml = tonumber(g.ml) or cfg.MAIN_LENGTH or 64
    local nb = math.max(1, math.floor((ml - 1) / sp))
    local perCorridor = (2 * bl + sp) + ml + 4 * bl * nb   -- spine, main, branches in and out
    local j = type(st.job) == "table" and st.job or {}
    local left = (cfg.MAX_CORRIDORS or 1) - (tonumber(j.corridor) or 0)
    if left < 0 then left = 0 end
    return math.max(0, left * perCorridor - (tonumber(j.branch) or 0) * 4 * bl)
end

local function estimateTripSec()
    local s = st.stats
    local rate = tonumber(s.moveSec) or DEFAULT_MOVE_SEC
    local d = 0
    local okD, pos = pcall(mine.jobStart, st.job)
    if okD and type(pos) == "table" then d = nav.dist(st.home, pos) end
    local est = (2 * d + remainingMoves()) * rate          -- the whole rest of the job
    local f = turtle.getFuelLevel()
    if type(f) == "number" then est = math.min(est, math.max(f, 2 * d) * rate) end   -- fuel runs out first
    local hist = tonumber(s.tripSec)
    if hist then est = math.min(est, math.max(hist, tonumber(s.lastTripSec) or hist)) end
    return math.max(MIN_TRIP_SEC, math.floor(est))
end

local function markDeparture()
    local s = st.stats
    s.tripStart = os.epoch("utc")
    local f = turtle.getFuelLevel()
    s.tripFuel0 = type(f) == "number" and f or nil
    s.tripNatural = nil
end

local function sendAway()
    local est = estimateTripSec()
    net.send("away", "server", {
        label = os.getComputerLabel() or ("miner-" .. os.getComputerID()),
        eta = os.epoch("utc") + est * 1000, est = est,
    })
end

local function markArrival()
    local m = net.mesh and net.mesh()
    if m then pcall(m.tripDone) end   -- update probation: a trip completed
    local s = st.stats
    if not s.tripStart then return end
    local dur = (os.epoch("utc") - s.tripStart) / 1000
    local f = turtle.getFuelLevel()
    if type(f) == "number" and type(s.tripFuel0) == "number" and s.tripFuel0 - f > 20 and dur > 0 then
        local r = dur / (s.tripFuel0 - f)
        s.moveSec = s.moveSec and (s.moveSec + r) / 2 or r
    end
    if s.tripNatural and dur > 0 then      -- only full trips (inventory full / fuel) predict the next
        s.lastTripSec = math.floor(dur)
        s.tripSec = s.tripSec and math.floor((s.tripSec + dur) / 2) or math.floor(dur)
    end
    s.tripStart, s.tripFuel0, s.tripNatural = nil, nil, nil
end

local function setPhase(p, reason)
    local leaving = p == "TO_WORK" and atHome() and st.phase ~= "TO_WORK"
    if leaving then markDeparture() end
    st.phase, st.reason = p, reason
    lastPhase = p
    save()
    if leaving then sendAway() end
    net.statusNow()
    drawStatus()
    log(p .. (reason and (": " .. tostring(reason)) or ""))
end

local function sendHomeSave()
    net.send("home_save", "server", { home = copyPos(st.home), homeFacing = st.homeFacing, gps = st.gps and true or false })
end

local function sendHello()
    net.send("hello", "server", {
        label = os.getComputerLabel() or ("miner-" .. os.getComputerID()),
        version = VERSION, gps = st and st.gps and true or false,
        cfg = { targetY = cfg.TARGET_Y, focus = cfg.FOCUS, branchLength = cfg.BRANCH_LENGTH,
                mainLength = cfg.MAIN_LENGTH, maxCorridors = cfg.MAX_CORRIDORS },
    })
end

-- Status ---------------------------------------------------------------------

local function slotsUsed()
    local n = 0
    for i = 1, 16 do if turtle.getItemCount(i) > 0 then n = n + 1 end end
    return n
end

local function getStatus()
    local fuel = turtle.getFuelLevel()
    local s = {
        label = os.getComputerLabel() or ("miner-" .. os.getComputerID()),
        version = VERSION,
        phase = "BOOT",
        fuel = fuel,
        slotsUsed = slotsUsed(),
        cfg = { targetY = cfg.TARGET_Y, focus = cfg.FOCUS },
    }
    if not st then return s end
    local need = 0
    local okN, n = pcall(inv.fuelNeeded, st)
    if okN and type(n) == "number" then need = n
    else
        local okD, d = pcall(nav.fuelToHome, st)
        if okD and type(d) == "number" then need = d + (cfg.FUEL_MARGIN or 0) end
    end
    local job = st.job or {}
    s.phase = st.phase or "BOOT"
    s.reason = st.reason
    s.pos = copyPos(st.pos)
    s.facing = st.facing
    s.home = copyPos(st.home)
    s.gps = st.gps and true or false
    s.gpsHost = net.gpsHost() or nil
    s.fuelNeeded = need
    s.job = { corridor = job.corridor, branch = job.branch, side = job.side, step = job.step }
    s.stats = { ores = st.stats.ores, blocks = st.stats.blocks, trips = st.stats.trips,
                uptime = math.floor(os.clock()) }
    s.army = group.status()
    s.lastError = st.lastError and string.sub(st.lastError, 1, 200) or nil
    return s
end

-- Commands -------------------------------------------------------------------

-- Coerces SET values sent as strings ("-50", "true") to the default's type.
local function coerce(key, value)
    local def = config.DEFAULTS[key]
    if type(def) == "number" and type(value) == "string" then return tonumber(value) end
    if type(def) == "boolean" and type(value) == "string" then
        if value == "true" then return true elseif value == "false" then return false end
    end
    return value
end

-- Used by net for the ack: lets a bad SET be refused on the wire.
local function validateCmd(cmd, params)
    if cmd == "SET" then
        local key = params.key
        local check = config.REMOTE_KEYS[key]
        if not check then return false, "unknown or read-only key: " .. tostring(key) end
        params.value = coerce(key, params.value)
        if not check(params.value) then return false, "invalid value for " .. key end
        if key == "HOME_Y" and st and not st.gps and not atHome() then
            -- The relative frame and journal history would no longer agree.
            return false, "HOME_Y can only be set while the turtle is at home"
        end
    end
    return true
end

local function doResetHome(params)
    local f = tonumber(params.facing)
    if f then f = math.floor(f) % 4 end
    if st.lost then
        -- Position was unknown; the operator says we're at home. Keep frame and job.
        if st.gps then
            local p = nav.gpsLocate(true)
            if p then st.pos = copyPos(p); st.home = copyPos(p) else st.pos = copyPos(st.home) end
        else
            st.pos = copyPos(st.home)
        end
        st.facing = f or st.homeFacing
        st.homeFacing = st.facing
    else
        if st.gps then
            local p = nav.gpsLocate(true)
            if p then st.pos = copyPos(p) end
        end
        st.home = copyPos(st.pos)
        if f then st.facing = f end
        st.homeFacing = st.facing
        st.job = freshJob()   -- grid is relative to home; old job coords are meaningless now
    end
    st.lost = nil
    st.facingUnknown = nil
    st.facingCands = nil
    st.homeMarks = nil       -- rescanned at the next UNLOADING
    homeScanned = false
    st.flags.surfaced, st.flags.surfacing = nil, nil
    helpRetry = nil
    noRetreat = false
    homeOrder = nil
    req.homeReset = true
    -- The journal's history names cells around where the turtle believed it was; after
    -- "this spot is home" (maybe carried here) they are no evidence for the probe any more.
    state.save(st, true)
    sendHomeSave()
    net.event("info", "home reset to " .. st.home.x .. "," .. st.home.y .. "," .. st.home.z .. " facing " .. st.homeFacing)
end

local WAITING = { IDLE = true, DONE = true, PAUSED = true, NEEDS_HELP = true }

-- Army to join at the next UNLOADING at the station spot ("" = none).
local function setGroup(name)
    cfg.GROUP = name
    if settings and settings.set then
        pcall(settings.set, "tminer.GROUP", name)
        if settings.save then pcall(settings.save) end
    end
end

local function applyCmd(c)
    local name, params = c.cmd, c.params or {}
    -- Visible trace on the turtle's screen, so "the command arrived but nothing happened"
    -- can be told apart from "it never arrived".
    log(("cmd %s (%s) in %s"):format(tostring(name), c.isLocal and "key" or tostring(c.id), tostring(st and st.phase)))
    if name == "RETURN_HOME" then
        req.ret, req.pause = true, false
    elseif name == "PAUSE" then
        req.pause = true
    elseif name == "RESUME" then
        req.pause, req.ret, req.resume = false, false, true
        st.flags.afterHome = nil
    elseif name == "SET" then
        local key = params.key
        local value = coerce(key, params.value)
        local ok, err = config.set(key, value)
        if ok then
            cfg[key] = value
            if key == "HOME_Y" and st and not st.gps and atHome() then
                -- Relative frame: move the whole frame so home sits at the real Y. Only at
                -- home (validateCmd refuses otherwise); the journal history is in the old
                -- frame, so drop it and start from a fresh snapshot.
                local dy = value - st.home.y
                st.home.y = st.home.y + dy
                st.pos.y = st.pos.y + dy
                if st.lost == NEED_HOME_Y then st.lost = nil end
                pcall(state.wipe)
                save()
                sendHomeSave()
            end
            net.event("info", "set " .. tostring(key) .. " = " .. tostring(value))
        else
            net.event("warn", "SET failed: " .. tostring(err))
        end
    elseif name == "REQUEST_STATUS" then
        net.statusNow()
    elseif name == "RESET_JOB" then
        st.flags.resetJob = true
        save()
        net.event("info", "job will restart at corridor 0 next time at home")
    elseif name == "RESET_HOME" then
        doResetHome(params)
    elseif name == "UPDATE" then
        st.flags.update = true
        save()
        net.event("info", "update queued (runs next time at home, then carries on)")
    elseif name == "ARMY_JOIN" then
        if type(params.name) == "string" and params.name ~= "" then
            setGroup(params.name)
            net.event("info", "will join army " .. params.name .. " at the station spot")
            if WAITING[st.phase] then req.resume = true end
        end
    elseif name == "ARMY_LEAVE" then
        setGroup("")
        group.leave()
        if WAITING[st.phase] then req.resume = true end
    elseif name == "REBOOT" then
        -- Commands are only applied between steps, so the turtle is not moving.
        save()
        os.reboot()
    end
end

local function drain()
    while true do
        local c = net.poll()
        if not c then break end
        local ok, err = true, nil
        if c.cmd == "REBOOT" then applyCmd(c) else ok, err = pcall(applyCmd, c) end
        if not ok then net.event("error", "cmd " .. tostring(c.cmd) .. ": " .. tostring(err)) end
    end
    if st and st.phase ~= lastPhase then   -- phase changed inside nav/mine
        lastPhase = st.phase
        net.statusNow()
    end
end

-- Called by mine between every step. May block while PAUSED.
function ctl.check()
    drain()
    if req.pause and not req.ret and not req.homeReset then
        local prev = st.phase
        setPhase("PAUSED", "paused by command")
        while req.pause and not req.ret and not req.homeReset do
            sleep(1)
            drain()
        end
        req.resume = false
        setPhase(prev, nil)
    end
    if req.homeReset then return "stop" end
    if req.ret then return "return" end
    return nil
end

-- Polled by nav inside retry loops. Only aborts work, never a trip home.
local function shouldAbort()
    drain()
    return (WORK[st.phase] and (req.ret or req.homeReset)) and true or false
end

-- nav saves every SNAPSHOT_EVERY moves itself; this only reports phase changes.
local function onMove()
    if st.phase ~= lastPhase then
        lastPhase = st.phase
        net.statusNow()
    end
end

-- Sleeps up to `sec` seconds serving commands; returns early on a control request.
local function waitFor(sec, extra)
    local t = 0
    while true do
        drain()
        if req.resume or req.ret or req.homeReset or (extra and extra()) then return true end
        if t >= sec then return false end
        sleep(1)
        t = t + 1
    end
end

-- Trips ----------------------------------------------------------------------

local function goHome()
    if st.gps then
        local p = nav.gpsLocate()
        if p and not samePos(p, st.pos) then
            net.event("warn", "gps correction " .. st.pos.x .. "," .. st.pos.y .. "," .. st.pos.z
                .. " -> " .. p.x .. "," .. p.y .. "," .. p.z)
            st.pos = copyPos(p)
            save()
        end
    end
    if not atHome() then
        -- Walk back through our own tunnels to the shaft first; a straight goTo
        -- at mining depth would cut new tunnels through rock.
        if not st.lost and not noRetreat then
            local okc, rok, rreason, rdetail = pcall(mine.retreat)
            if okc and not rok and rreason == "no_fuel" then
                pcall(inv.refuel, inv.fuelNeeded(st), { emergency = true })
                okc, rok, rreason, rdetail = pcall(mine.retreat)
            end
            -- A protected block (chest, computer, turtle) in our own tunnels: don't
            -- fall back to a digging goTo, ask for help instead.
            if okc and not rok and rreason == "stuck" then
                return false, "stuck: " .. tostring(rdetail or "retreat blocked")
            end
        end
        local ok, reason = nav.goTo(st.home, { order = homeOrder })
        if not ok and reason == "no_fuel" then
            -- Stranded: burn anything, including the FUEL_KEEP reserve (older inv ignores opts).
            pcall(inv.refuel, inv.fuelNeeded(st), { emergency = true })
            ok, reason = nav.goTo(st.home, { order = homeOrder })
        end
        if not ok then return false, reason end
    end
    noRetreat = false
    homeOrder = nil
    nav.face(st.homeFacing)
    return true
end

-- Fuel to leave home: home -> job start (incl. the vertical shaft) and back, plus
-- FUEL_MARGIN each way. Pure function of home, job geometry and cfg: same answer every call.
local function tripFuel()
    local d = 0
    local ok, pos = pcall(mine.jobStart, st.job)
    if ok and type(pos) == "table" then d = nav.dist(st.home, pos) end
    return 2 * d + 2 * (cfg.FUEL_MARGIN or 0)
end

-- Fuel this boot already burned at home (facing calibration) before the first fuel
-- check. Added to the reported need and to the fuel we count as "have" so that a
-- turtle started with exactly the reported need passes the same check next boot.
local function measureHomeOverhead()
    if bootFuel and type(bootFuel) == "number" and bootFuel ~= math.huge then
        local spent = bootFuel - fuelLevel()
        if spent > 0 then homeOverhead = spent end
    end
    bootFuel = nil
end

-- Mesh update fetched and complete (or a bad release to roll back): install at home.
local function meshReady()
    if cfg.AUTO_UPDATE == false then return false end
    local m = net.mesh and net.mesh()
    if not m then return false end
    local ok, r = pcall(m.ready)
    return ok and r ~= nil
end

-- Runs the updater (installs what the mesh fetched; after an UPDATE command it asks the
-- network first and waits up to 20 s at home). If something was installed, saves `after` as
-- the phase to come back to and reboots once (startup -> miner -> resumePhase).
local function runUpdate(after, afterReason)
    local asked = st.flags.update
    st.flags.update = false
    save()
    net.event("info", asked and "running updater" or "installing update")
    local updated = false
    -- updater.run(opts) -> updated(bool), info; it never reboots, we decide.
    local okR, mod = pcall(require, "updater")
    if okR and type(mod) == "table" and type(mod.run) == "function" then
        local ok, r = pcall(mod.run, { mesh = net.mesh and net.mesh() or nil, wait = asked and 20 or 0 })
        if ok then updated = (r == true) else net.event("warn", "updater failed: " .. firstLine(r)) end
    else
        net.event("warn", "updater not available: " .. firstLine(mod))
    end
    if updated then
        net.event("info", "updated, rebooting")
        st.phase, st.reason = after or st.phase, afterReason
        save()
        os.reboot()
    else
        net.event("info", "no update installed; carrying on")
    end
end

-- What to do once home, unloaded and refuelled.
local function nextAfterHome()
    if st.flags.afterHome == "IDLE" or req.ret then
        req.ret = false
        st.flags.afterHome = nil
        return "IDLE", "returned by command"
    end
    if st.flags.afterHome == "DONE" then
        st.flags.afterHome = nil
        return "DONE", "all corridors mined"
    end
    if req.pause then req.pause = false; return "PAUSED", "paused by command" end
    return "TO_WORK"
end

-- Where to continue after a reboot or a RESUME.
local function resumePhase(p)
    if p == "PAUSED" then return "PAUSED" end   -- stays where it is until RESUME
    if p == "IDLE" or p == "DONE" then
        return atHome() and p or "RETURNING"
    end
    if WORK[p] then return "TO_WORK" end
    return atHome() and "UNLOADING" or "RETURNING"
end

-- Phase handlers: each returns nextPhase, reason (nil = stay) ----------------

local H = {}

H.RETURNING = function()
    local ok, reason = goHome()
    if ok then
        bootFuel, homeOverhead = nil, 0   -- fuel burned getting here is not boot overhead
        st.stats.trips = st.stats.trips + 1
        markArrival()
        return "UNLOADING"
    end
    helpRetry = function()
        if goHome() then return "UNLOADING" end
    end
    return "NEEDS_HELP", "cannot return home: " .. tostring(reason)
end

local function storageReason(reason)
    if reason == "storage_full" then return "storage full" end
    if reason == "no_storage" then return "no storage at home" end
    return tostring(reason)
end

H.UNLOADING = function()
    if not atHome() then return "RETURNING" end
    local want = group.wantJoin()
    if want then
        local ok, why = group.join(want)
        if not ok then
            helpRetry = function() return "UNLOADING" end
            return "NEEDS_HELP", "army join failed: " .. tostring(why)
        end
        homeScanned = false
        sendHomeSave()
    end
    if group.consumeLeft() then
        homeScanned = false
        noRetreat, homeOrder = true, "xzy"
        sendHomeSave()
        if not atHome() then return "RETURNING", "left the army, back to the solo home" end
    end
    if not homeScanned then
        local h = inv.scanHome()
        homeScanned = true
        -- Remember which way the home storage is (world facing -> block name): a turn crash at
        -- home or in the shaft can then be settled by probing at home (nav.recover).
        local marks = {}
        local OFF = { front = 0, right = 1, back = 2, left = 3 }
        for side, info in pairs(type(h) == "table" and h.sides or {}) do
            if OFF[side] and type(info) == "table" and type(info.name) == "string" then
                marks[(st.homeFacing + OFF[side]) % 4] = info.name
            end
        end
        st.homeMarks = marks
        save()
    end
    local ok, reason = inv.unload()
    if ok then return "REFUELING" end
    helpRetry = function()
        inv.scanHome()
        if inv.unload() then return "REFUELING" end
    end
    return "NEEDS_HELP", storageReason(reason)
end

H.REFUELING = function()
    if st.flags.resetJob then
        st.job = freshJob()
        st.flags.resetJob = false
        net.event("info", "job reset to corridor 0")
    end
    local nxt, why = nextAfterHome()
    if st.flags.update or meshReady() then
        -- After an update reboot, come back to what we were about to do.
        -- REFUELING (not TO_WORK) so the fuel check still runs after the reboot.
        runUpdate(nxt == "TO_WORK" and "REFUELING" or nxt, nxt ~= "TO_WORK" and why or nil)
    end
    if fuelLevel() == math.huge then return nxt, why end
    measureHomeOverhead()
    -- One calculation for the check and the report: `need` is what a fresh boot must start with.
    local trip = tripFuel()
    local need = trip + homeOverhead
    local function short() return fuelLevel() + homeOverhead < need end
    local target = cfg.FUEL_TARGET or 0
    if trip > target then target = trip end
    inv.restockFuel(target)
    if nxt ~= "TO_WORK" then return nxt, why end
    -- At home and still short: burn whatever fuel we carry, reserve included
    -- (the reserve is for getting home, and we are home).
    if short() then inv.refuel(trip, { emergency = true }) end
    local function reason()
        local carried = 0
        for i = 1, 16 do
            local d = turtle.getItemDetail(i)
            if d and inv.fuelValue(d.name) then carried = carried + d.count end
        end
        return "out of fuel (have " .. fuelLevel() .. ", need " .. need
            .. (homeOverhead > 0 and (" incl. " .. homeOverhead .. " used at home since boot") or "")
            .. "; carrying " .. carried .. " fuel items"
            .. (inv.home and inv.home.fuel and "" or "; no fuel chest found") .. ")"
    end
    if short() then
        helpRetry = function()
            inv.restockFuel(target)
            if short() then inv.refuel(trip, { emergency = true }) end
            if not short() then return "REFUELING" end
            -- Keep the reason current so the monitor shows the real level.
            local r = reason()
            if st.reason ~= r then st.reason = r; net.statusNow() end
        end
        return "NEEDS_HELP", reason()
    end
    homeOverhead = 0
    return "TO_WORK"
end

-- Army: claim -> mine the branch -> claim_done. Returns mine.run style results plus
-- "wait" (reason = seconds), "next" (branch done, claim another), "home", "leave", "armyret".
local function armyRun()
    local s = group.settings()
    if s.RETURN then
        if atHome() then return "wait", 10 end
        return "armyret", "army return"
    end
    local job, wait, silent = group.nextJob()
    if not job then
        if group.leaving() then return "leave", "leaving the army" end
        if silent and not atHome() then return "home", "no answer from the army server" end
        return "wait", wait or 5
    end
    if job.dig_shaft then
        if st.pos.y < st.home.y then   -- claimed at depth: the second shaft starts at the station spot
            local ok, why, detail = mine.retreat()
            if not ok then return "stuck", tostring(detail or why) end
            group.stationRelease()
        end
        local res, why = mine.digShaft(group.deepest())
        if res == "done" then group.shaftDone(); return "next" end
        return res, why
    end
    if st.phase ~= "MINING" then setPhase("MINING", "branch " .. tostring(job.key)) end
    local res, why = mine.runBranch(job)
    if res == "done" then
        group.jobDone(job, mine.armyResult())
        if group.leaving() then return "leave", "leaving the army" end
        if not net.inContact() then return "home", "branch done, out of contact" end
        return "next"
    end
    return res, why
end

local function work()
    drain()
    if req.homeReset then req.homeReset = false; return "IDLE", "home reset" end
    if req.ret then
        req.ret = false; st.flags.afterHome = "IDLE"
        return "RETURNING", "return command"
    end
    local result, reason
    if group.active() then result, reason = armyRun() else result, reason = mine.run() end
    if req.homeReset then req.homeReset = false; return "IDLE", "home reset" end
    if req.ret or result == "return" then
        req.ret = false; st.flags.afterHome = "IDLE"
        return "RETURNING", "return command"
    end
    if result == "wait" then waitFor(tonumber(reason) or 5); return nil end
    if result == "next" then return nil end
    if result == "home" or result == "leave" then return "RETURNING", reason end
    if result == "armyret" then st.flags.afterHome = "IDLE"; return "RETURNING", reason end
    if (result == "full" or result == "fuel") and atHome() then
        -- Nothing gained by another trip: unloading/refuelling didn't help.
        helpRetry = function() return "UNLOADING" end
        return "NEEDS_HELP", result == "full" and "inventory full at home" or "not enough fuel at home"
    end
    if result == "full" or result == "fuel" or result == "done" then st.flags.stuckRetries = nil end
    if result == "full" or result == "fuel" then st.stats.tripNatural = true end
    if result == "full" then return "RETURNING", "inventory full" end
    if result == "fuel" then return "RETURNING", "low fuel" end
    if result == "done" then st.flags.afterHome = "DONE"; return "RETURNING", "job done" end
    if result == "stop" then st.flags.afterHome = "IDLE"; return "RETURNING", "stopped" end
    -- "stuck" or anything unexpected: get home if we can, then ask for help.
    local why = "stuck: " .. tostring(reason or result)
    setPhase("RETURNING", why)
    local ok = goHome()
    helpRetry = nil
    local where = ok and " (at home)" or " (could not get home)"
    local n = tonumber(st.flags.stuckRetries) or 0
    if string.find(why, "unbreakable", 1, true) then
        return "NEEDS_HELP", why .. where   -- bedrock won't go away by waiting
    end
    if n >= STUCK_RETRIES then
        return "NEEDS_HELP", why .. where .. "; gave up after " .. n .. " retries"
    end
    -- Mobs, players, other turtles move on: try again later, a limited number of times.
    st.flags.stuckRetries = n + 1
    local wait = (cfg.HELP_RETRY or 30) * 4
    local at = os.clock() + wait
    helpRetry = function()
        if os.clock() < at then return nil end
        return atHome() and "UNLOADING" or "RETURNING", "retry " .. (n + 1) .. "/" .. STUCK_RETRIES .. " after " .. why
    end
    return "NEEDS_HELP", why .. where .. "; retry " .. (n + 1) .. "/" .. STUCK_RETRIES .. " in " .. wait .. "s"
end
H.TO_WORK, H.MINING, H.VEIN = work, work, work

local function idleLike(onResume)
    local isDone = st.phase == "DONE"
    if atHome() and (st.flags.update or meshReady()) then runUpdate(st.phase, st.reason) end
    waitFor(cfg.HELP_RETRY or 30, function() return atHome() and (st.flags.update or meshReady()) end)
    if req.homeReset then req.homeReset = false; return "IDLE", "home reset" end
    if req.resume then
        req.resume = false
        return onResume()
    end
    if req.ret then
        req.ret = false
        if not atHome() then st.flags.afterHome = isDone and "DONE" or "IDLE"; return "RETURNING", "return command" end
    end
    return nil
end

H.IDLE = function()
    return idleLike(function() return atHome() and "UNLOADING" or "TO_WORK" end)
end

H.DONE = function()
    return idleLike(function()
        if st.flags.resetJob then return "UNLOADING" end
        local corr = type(st.job) == "table" and tonumber(st.job.corridor) or 0
        if corr < (cfg.MAX_CORRIDORS or 1) then
            -- MAX_CORRIDORS was raised: carry on with the next corridor.
            return atHome() and "UNLOADING" or "TO_WORK"
        end
        net.event("info", "job complete; raise MAX_CORRIDORS or send RESET_JOB, then RESUME")
        return nil
    end)
end

H.PAUSED = function()
    req.pause = false
    return idleLike(function() return atHome() and "UNLOADING" or "TO_WORK" end)
end

H.NEEDS_HELP = function()
    waitFor(cfg.HELP_RETRY or 30)
    if req.homeReset then req.homeReset = false; helpRetry = nil; return "IDLE", "home reset" end
    if req.resume then
        req.resume = false
        if st.lost then
            net.event("warn", "position unknown: place at home and send RESET_HOME")
            return nil
        end
        helpRetry = nil
        st.flags.stuckRetries = nil      -- a person looked at it: fresh retry budget
        return atHome() and "UNLOADING" or "TO_WORK"
    end
    if req.ret then
        req.ret = false
        if not st.lost then
            if atHome() then helpRetry = nil; return "IDLE", "returned by command" end
            st.flags.afterHome = "IDLE"
            helpRetry = nil
            return "RETURNING", "return command"
        end
    end
    if helpRetry then
        local fn = helpRetry
        local nxt, why = fn()
        -- fn may have installed a new helpRetry (e.g. a failed facing calibration): keep that one.
        if nxt and helpRetry == fn then helpRetry = nil end
        if nxt then return nxt, why end
    end
    return nil
end

-- Boot -----------------------------------------------------------------------

function ctl.event(level, text) net.event(level, text) end

local function initModules()
    nav.init(st, { shouldAbort = shouldAbort, onMove = onMove, save = save, cfg = cfg,
                   onEvent = function(level, text) net.event(level, text); log(text) end,
                   isKnownOpen = function(p) return mine.isKnownOpen(p) end,
                   knownBlock = function(p)
                       -- storage next to home, recorded by the last home scan
                       local h = st.home
                       if type(st.homeMarks) ~= "table" or p.y ~= h.y then return nil end
                       for d, name in pairs(st.homeMarks) do
                           local v = ({ [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } })[tonumber(d)]
                           if v and p.x == h.x + v[1] and p.z == h.z + v[2] then return name end
                       end
                       return nil
                   end })
    inv.init(st, cfg, nav)
    mine.init(st, cfg, nav, inv, ctl)
    group.init(st, cfg, nav, inv, mine, net, ctl)
end

local function calibrateOrHelp()
    local ok, reason = nav.calibrateFacing()
    if ok then return true end
    local why = "facing unknown: " .. tostring(reason)
    st.lost = why            -- nav.goTo refuses until facing is known
    helpRetry = function()
        if nav.calibrateFacing() then
            st.lost = nil
            return atHome() and "UNLOADING" or "RETURNING"
        end
    end
    return false, why
end

-- SURFACE_IF_LOST: position lost after a crash. Dig straight up (nav.up never digs protected
-- blocks) until SURFACE_AIR open cells in a row were passed, an unbreakable/protected block is
-- above, or fuel would drop below SURFACE_MIN_FUEL; then wait for a person. A GPS turtle tries
-- GPS every 16 blocks on the way up (underground it is out of modem range) and, with a fix,
-- calibrates its facing and goes home on its own. Never starts from home, the shaft column or
-- above home (it would dig through the base). Returns nextPhase, reason, or nil (not done).
local SURFACED = "lost: surfaced here, carry me home and press H twice"
local SURFACE_AIR, SURFACE_MIN_FUEL, SURFACE_MAX = 8, 50, 400

-- GPS fix while surfacing: position known again; calibrate facing and go home across at this
-- height, then down. Returns true when the turtle can go home on its own.
local function surfaceFix(force)
    local g = nav.gpsLocate(force)
    if not g then return false end
    st.pos = copyPos(g)
    st.lost = nil
    st.flags.surfacing = nil
    if not calibrateOrHelp() then return false end
    noRetreat, homeOrder = true, "xzy"
    save()
    net.event("info", "lost turtle surfaced into GPS range at " .. g.x .. "," .. g.y .. "," .. g.z)
    log("GPS fix at " .. g.x .. "," .. g.y .. "," .. g.z .. ": going home")
    return true
end

local function surfaceIfLost()
    if not cfg.SURFACE_IF_LOST or not st.lost or st.flags.surfaced then return nil end
    if not st.flags.surfacing then
        local p, h = st.pos, st.home
        if p.y >= h.y - 3 or (p.x == h.x and p.z == h.z) or nav.dist(p, h) <= 3 then return nil end
        st.flags.surfacing = true   -- a reboot mid-climb carries on climbing
        save()
    end
    log("lost: climbing to the surface")
    local HOME_GO = "surfaced into GPS range, going home"
    local air, moves, why = 0, 0, nil
    while air < SURFACE_AIR and moves < SURFACE_MAX do
        local f = turtle.getFuelLevel()
        if f ~= "unlimited" and f - 1 < SURFACE_MIN_FUEL then why = "fuel low"; break end
        local blocked = turtle.detectUp()
        local ok, r = nav.up(true)
        if not ok then why = tostring(r); break end
        moves = moves + 1
        if blocked then air = 0 else air = air + 1 end
        if st.gps and moves % 16 == 0 and surfaceFix() then return "RETURNING", HOME_GO end
    end
    if st.gps and surfaceFix(true) then return "RETURNING", HOME_GO end
    st.flags.surfacing = nil
    st.flags.surfaced = true
    st.lost = SURFACED
    helpRetry = nil
    save()
    log("surfaced after " .. moves .. " blocks" .. (why and (" (" .. why .. ")") or ""))
    return "NEEDS_HELP", SURFACED
end

-- Returns the first phase to run, reason.
local function boot()
    local loaded = state.load()
    if loaded then
        st = loaded
        normalize(st)
        initModules()
        local prev = st.phase
        -- No save before nav.recover: a snapshot written now would carry the stale snapshot
        -- position and supersede the journal lines (and dangling intent) written after it.
        st.phase, st.reason = "RECOVER", nil
        lastPhase = "RECOVER"
        net.statusNow()
        log("RECOVER")
        local ok, reason = nav.recover(st)
        sendHello()
        sendHomeSave()
        if not ok then
            -- nav.recover already set st.lost / NEEDS_HELP; keep its reason.
            st.lost = st.lost or tostring(reason or "position unknown after crash")
            local sp, sr = surfaceIfLost()
            if sp then return sp, sr end
            if st.lost == SURFACED then return "NEEDS_HELP", SURFACED end
            return "NEEDS_HELP", tostring(reason or "position unknown after crash")
                .. "; place at home and send RESET_HOME"
        end
        net.event("info", "recovered at " .. st.pos.x .. "," .. st.pos.y .. "," .. st.pos.z)
        return resumePhase(prev)
    end

    -- No local state.
    st = state.new({ x = 0, y = 0, z = 0 }, 0, true)
    normalize(st)
    st.phase = "BOOT"
    initModules()
    local p = nav.gpsLocate()
    local rec = net.request("home_get", {}, "home", 3)
    local found = rec and rec.found and type(rec.home) == "table"
    if p then
        st.gps = true
        st.pos = copyPos(p)
        if found and rec.gps then
            -- State file lost but the server knows our world home. Only trust it when we are
            -- next to it (or in its shaft): walking a long way back would dig through anything
            -- in between, and the turtle may simply have been set up somewhere new.
            local h = copyPos(rec.home)
            local hf = math.floor(tonumber(rec.homeFacing) or 0) % 4
            if nearHome(p, h) then
                st.home, st.homeFacing = h, hf
                local ok, why = calibrateOrHelp()
                sendHello()
                if not ok then return "NEEDS_HELP", why end
                noRetreat = true
                net.event("warn", "state lost; home restored from server, job restarts at corridor 0")
                return atHome() and "UNLOADING" or "RETURNING"
            end
            -- Learn our facing (one block out and back) so RESET_HOME here gets it right.
            local okp, okc = pcall(nav.calibrateFacing)
            okc = okp and okc
            st.facingUnknown = nil
            st.home, st.homeFacing = h, st.facing
            st.lost = LOST_FAR
            sendHello()
            helpRetry = function()
                -- Carried home by hand? Then adopt the record after all.
                local q = nav.gpsLocate()
                if not (q and nearHome(q, h)) then return nil end
                st.pos, st.home, st.homeFacing = copyPos(q), h, hf
                st.lost = nil
                local ok, why = calibrateOrHelp()
                if not ok then return "NEEDS_HELP", why end
                noRetreat = true
                net.event("info", "back at the recorded home; job restarts at corridor 0")
                return atHome() and "UNLOADING" or "RETURNING"
            end
            net.event("warn", "state lost " .. nav.dist(p, h) .. " blocks from home record "
                .. h.x .. "," .. h.y .. "," .. h.z .. "; not walking there")
            return "NEEDS_HELP", LOST_FAR .. (okc and "" or " (facing not calibrated)")
        end
        st.home = copyPos(p)
        local ok, why = calibrateOrHelp()
        st.homeFacing = st.facing
        sendHello()
        sendHomeSave()
        if not ok then return "NEEDS_HELP", why end
        net.event("info", "new home (gps) " .. p.x .. "," .. p.y .. "," .. p.z)
        return atHome() and "UNLOADING" or "RETURNING"
    end

    st.gps = false
    local hy = (cfg.HOME_Y ~= UNSET_Y) and cfg.HOME_Y or 0
    st.pos, st.home = { x = 0, y = hy, z = 0 }, { x = 0, y = hy, z = 0 }
    st.facing, st.homeFacing = 0, 0
    sendHello()
    if found then
        st.lost = "state lost: place at home and send RESET_HOME"
        return "NEEDS_HELP", "state lost: place at home and send RESET_HOME"
    end
    if cfg.HOME_Y == UNSET_Y then
        st.lost = NEED_HOME_Y
        save()
        return "NEEDS_HELP", NEED_HOME_Y
    end
    sendHomeSave()
    net.event("info", "new home (relative frame)")
    return "UNLOADING"
end

-- Worker ---------------------------------------------------------------------

local function loop()
    while true do
        local h = H[st.phase]
        if not h then
            setPhase(resumePhase(st.phase))
        else
            local nxt, reason = h()
            if nxt and (nxt ~= st.phase or reason ~= st.reason) then setPhase(nxt, reason) end
        end
        yield()
    end
end

local function body()
    if not booted then
        local nxt, reason = boot()
        booted = true
        setPhase(nxt, reason)
    end
    loop()
end

local function onError(err)
    err = tostring(err)
    if string.find(err, "Terminated", 1, true) then error(err, 0) end
    log("ERROR: " .. err)
    net.event("error", string.sub(err, 1, 200))
    if not booted or not st then
        -- Boot itself failed: report and retry boot later.
        if st then st.lastError = string.sub(err, 1, 200); st.phase = "ERROR"; st.reason = firstLine(err) end
        net.statusNow()
        sleep(cfg.HELP_RETRY or 30)
        return
    end
    st.lastError = string.sub(err, 1, 200)
    pcall(setPhase, "ERROR", firstLine(err))
    -- Try to get home once.
    local okH, home = pcall(function()
        setPhase("RETURNING", "after error")
        return goHome()
    end)
    helpRetry = nil
    pcall(setPhase, "NEEDS_HELP", "error: " .. firstLine(err)
        .. ((okH and home) and " (at home)" or " (not at home)"))
    sleep(1)
end

local function worker()
    while true do
        local ok, err = xpcall(body, debug.traceback)
        if ok then return end
        onError(err)
    end
end

net.init(cfg)
net.setValidator(validateCmd)
net.setGpsPos(function() return st and st.gps and type(st.pos) == "table" and st.pos or nil end)
if net.mesh and net.mesh() then net.mesh().o.atHome = function() return st ~= nil and atHome() end end
-- Keyboard controls on the turtle itself, so it can be run with no monitor or modem.
local KEYHELP = "Keys: R resume  P pause  B return home  S status  H twice = this is home  N network to disk  J join army  L leave army"
local function keyboard()
    local lastH = 0
    while true do
        local _, ch = os.pullEvent("char")
        ch = ch:lower()
        if ch == "r" then net.pushLocal("RESUME"); print("> RESUME")
        elseif ch == "p" then net.pushLocal("PAUSE"); print("> PAUSE")
        elseif ch == "b" then net.pushLocal("RETURN_HOME"); print("> RETURN_HOME")
        elseif ch == "s" then
            drawStatus()
            print(("> %s %s | pos %d,%d,%d | fuel %s"):format(tostring(st and st.phase), tostring(st and st.reason or ""),
                st and st.pos.x or 0, st and st.pos.y or 0, st and st.pos.z or 0, tostring(turtle.getFuelLevel())))
        elseif ch == "h" then
            local now = os.epoch("utc")
            if now - lastH < 5000 then
                net.pushLocal("RESET_HOME"); print("> RESET_HOME (this spot is home)")
                lastH = 0
            else
                lastH = now
                print("> press H again within 5 s to make this spot home")
            end
        elseif ch == "n" then
            -- Copy this turtle's mining network to a floppy in a drive next to it (join without typing).
            local okJ, J = pcall(require, "tmjoin")
            if not okJ then print("> tmjoin.lua missing")
            else
                local okD, err = J.toDisk()
                print(okD and "> network copied to the disk" or ("> " .. tostring(err)))
            end
        elseif ch == "j" then
            write("Army to join (at its station spot): ")
            local n = read()
            if n and n ~= "" then net.pushLocal("ARMY_JOIN", { name = n }); print("> ARMY_JOIN " .. n) end
        elseif ch == "l" then net.pushLocal("ARMY_LEAVE"); print("> ARMY_LEAVE")
        elseif ch == "?" then print(KEYHELP)
        end
    end
end

setupScreen()
drawStatus()
print(KEYHELP)
if not net.network() then print("No mining network: works offline. Run 'install --network' to join one.") end
parallel.waitForAny(worker, function() net.run(getStatus) end, keyboard, screenLoop)
