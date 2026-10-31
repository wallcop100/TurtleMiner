-- Version: 1.1.2
-- TurtleMiner main program. Two coroutines only:
--   worker : the only code that moves the turtle (state machine over st.phase)
--   net.run: receives commands, acks them, sends status
-- Never prompts. Problems end in NEEDS_HELP with a reason, never in read().

local VERSION = "1.0.0"

local config = require("config")
local state  = require("state")
local nav    = require("nav")
local inv    = require("inv")
local mine   = require("mine")
local net    = require("net")

local cfg = config.load()
local st            -- state table, shared by reference with nav/inv/mine
local booted = false
local ctl = {}

local WORK = { TO_WORK = true, MINING = true, VEIN = true }
local UNSET_Y = -9999
local NEED_HOME_Y = "no GPS: set HOME_Y to this turtle's Y level (SET HOME_Y), then RESUME"

-- Runtime control requests (set by commands, consumed by the worker).
local req = { ret = false, pause = false, resume = false, homeReset = false }
local helpRetry      = nil    -- fn() -> nextPhase, reason | nil  (NEEDS_HELP auto retry)
local lastPhase      = nil
local homeScanned    = false
-- Fuel at program start; consumed by the first REFUELING that is still at the boot home.
local bootFuel       = turtle.getFuelLevel()
local homeOverhead   = 0      -- fuel spent at home after boot (facing calibration) before leaving

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

local function setPhase(p, reason)
    st.phase, st.reason = p, reason
    lastPhase = p
    save()
    net.statusNow()
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
    s.fuelNeeded = need
    s.job = { corridor = job.corridor, branch = job.branch, side = job.side, step = job.step }
    s.stats = { ores = st.stats.ores, blocks = st.stats.blocks, trips = st.stats.trips,
                uptime = math.floor(os.clock()) }
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
    end
    return true
end

local function doResetHome(params)
    local f = tonumber(params.facing)
    if f then f = math.floor(f) % 4 end
    if st.lost then
        -- Position was unknown; the operator says we're at home. Keep frame and job.
        if st.gps then
            local p = nav.gpsLocate()
            if p then st.pos = copyPos(p); st.home = copyPos(p) else st.pos = copyPos(st.home) end
        else
            st.pos = copyPos(st.home)
        end
        st.facing = f or st.homeFacing
        st.homeFacing = st.facing
    else
        if st.gps then
            local p = nav.gpsLocate()
            if p then st.pos = copyPos(p) end
        end
        st.home = copyPos(st.pos)
        if f then st.facing = f end
        st.homeFacing = st.facing
        st.job = freshJob()   -- grid is relative to home; old job coords are meaningless now
    end
    st.lost = nil
    st.facingUnknown = nil
    helpRetry = nil
    req.homeReset = true
    save()
    sendHomeSave()
    net.event("info", "home reset to " .. st.home.x .. "," .. st.home.y .. "," .. st.home.z .. " facing " .. st.homeFacing)
end

local function applyCmd(c)
    local name, params = c.cmd, c.params or {}
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
            if key == "HOME_Y" and st and not st.gps then
                -- Relative frame: move the whole frame so home sits at the real Y.
                local dy = value - st.home.y
                st.home.y = st.home.y + dy
                st.pos.y = st.pos.y + dy
                if st.lost == NEED_HOME_Y then st.lost = nil end
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
        net.event("info", "update queued (runs when idle at home)")
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
        if not st.lost then pcall(mine.retreat) end
        local ok, reason = nav.goTo(st.home)
        if not ok and reason == "no_fuel" then
            inv.refuel(inv.fuelNeeded(st))
            ok, reason = nav.goTo(st.home)
        end
        if not ok then return false, reason end
    end
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

local function runUpdate()
    st.flags.update = false
    save()
    net.event("info", "running updater")
    local updated = false
    -- updater.run(opts) -> updated(bool), info; it never reboots, we decide.
    local okR, mod = pcall(require, "updater")
    if okR and type(mod) == "table" and type(mod.run) == "function" then
        local ok, r = pcall(mod.run, {})
        if ok then updated = (r == true) else net.event("warn", "updater failed: " .. firstLine(r)) end
    else
        net.event("warn", "updater not available: " .. firstLine(mod))
    end
    if updated then
        net.event("info", "updated, rebooting")
        save()
        os.reboot()
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
    if st.flags.update then return "IDLE", "update pending" end
    if req.pause then req.pause = false; return "PAUSED", "paused by command" end
    return "TO_WORK"
end

-- Where to continue after a reboot or a RESUME.
local function resumePhase(p)
    if p == "IDLE" or p == "DONE" or p == "PAUSED" then
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
    if not homeScanned then inv.scanHome(); homeScanned = true end
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
    if short() then inv.refuel(trip) end
    if short() then
        helpRetry = function()
            inv.restockFuel(target)
            if short() then inv.refuel(trip) end
            if not short() then return "REFUELING" end
        end
        return "NEEDS_HELP", "out of fuel (have " .. fuelLevel() .. ", need " .. need
            .. (homeOverhead > 0 and (" incl. " .. homeOverhead .. " used at home since boot") or "") .. ")"
    end
    homeOverhead = 0
    return "TO_WORK"
end

local function work()
    drain()
    if req.homeReset then req.homeReset = false; return "IDLE", "home reset" end
    if req.ret then
        req.ret = false; st.flags.afterHome = "IDLE"
        return "RETURNING", "return command"
    end
    local result, reason = mine.run()
    if req.homeReset then req.homeReset = false; return "IDLE", "home reset" end
    if req.ret or result == "return" then
        req.ret = false; st.flags.afterHome = "IDLE"
        return "RETURNING", "return command"
    end
    if (result == "full" or result == "fuel") and atHome() then
        -- Nothing gained by another trip: unloading/refuelling didn't help.
        helpRetry = function() return "UNLOADING" end
        return "NEEDS_HELP", result == "full" and "inventory full at home" or "not enough fuel at home"
    end
    if result == "full" then return "RETURNING", "inventory full" end
    if result == "fuel" then return "RETURNING", "low fuel" end
    if result == "done" then st.flags.afterHome = "DONE"; return "RETURNING", "job done" end
    if result == "stop" then st.flags.afterHome = "IDLE"; return "RETURNING", "stopped" end
    -- "stuck" or anything unexpected: get home if we can, then ask for help.
    local why = "stuck: " .. tostring(reason or result)
    setPhase("RETURNING", why)
    local ok = goHome()
    helpRetry = nil
    return "NEEDS_HELP", why .. (ok and " (at home)" or " (could not get home)")
end
H.TO_WORK, H.MINING, H.VEIN = work, work, work

local function idleLike(onResume)
    local isDone = st.phase == "DONE"
    if atHome() and st.flags.update then runUpdate() end
    waitFor(cfg.HELP_RETRY or 30, function() return atHome() and st.flags.update end)
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
        net.event("info", "job complete; send RESET_JOB then RESUME to start again")
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
        local nxt, why = helpRetry()
        if nxt then helpRetry = nil; return nxt, why end
    end
    return nil
end

-- Boot -----------------------------------------------------------------------

function ctl.event(level, text) net.event(level, text) end

local function initModules()
    nav.init(st, { shouldAbort = shouldAbort, onMove = onMove, save = save, cfg = cfg,
                   onEvent = function(level, text) net.event(level, text) end })
    inv.init(st, cfg, nav)
    mine.init(st, cfg, nav, inv, ctl)
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
            -- State file lost but the server knows our world home: we may be mid-job.
            st.home = copyPos(rec.home)
            st.homeFacing = math.floor(tonumber(rec.homeFacing) or 0) % 4
            local ok, why = calibrateOrHelp()
            sendHello()
            if not ok then return "NEEDS_HELP", why end
            net.event("warn", "state lost; home restored from server, job restarts at corridor 0")
            return atHome() and "UNLOADING" or "RETURNING"
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
parallel.waitForAny(worker, function() net.run(getStatus) end)
