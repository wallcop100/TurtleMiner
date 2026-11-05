-- Version: 1.2.0
-- TurtleMiner server: ONE program for every server PC (docs/CLUSTER_GPS_PLAN.md section 1).
-- Each PC works out its roles at boot and every 60 s (and when a peripheral changes):
--   monitor attached / pocket      -> UI (keyboard first; touch and mouse are extras)
--   wireless or ender modem        -> radio gateway (talks to turtles, relays: docs/COMMS.md)
--   wired modem                    -> cluster link (relays between wired and the air too)
--   /files/ folder                 -> update server (+ GitHub pull)
--   wireless + GPS module present  -> GPS host (servers/tm_gps.lua + tm_gpssolve.lua: offer, anchor, host)
--   always (not on a pocket)       -> cluster member: one leader owns the database, the
--                                     others keep a replica and take over if it goes silent.
-- The loops run side by side with `parallel` (never multishell), so a basic computer works.
-- A pocket computer runs as a client: it shows the leader's `fleet` and sends `cmd_relay`.
--
-- Files next to this program: tm_db, tm_radio, tm_cluster, tm_ui, tm_views, tm_update (.lua),
-- tmcrypto.lua (signing), tmmesh.lua + tmguard.lua (mesh updates: every PC and pocket fetches,
-- serves and applies updates; applied when nobody used the PC for 30 s and no command is in
-- flight, then one restart; docs/MESH_UPDATE_PLAN.md). Mining network: .tm_network (`setup network` creates or joins one);
-- without it the PC sends and accepts nothing.
-- Usage: tminer_server [monitorSide|auto|none] [textScale]      (tminer_server --lib -> API)

local args = { ... }
local T = {}

-- ---------------------------------------------------------------------------
-- Modules: loaded into the shared table T, from the program's folder or the root.
-- ---------------------------------------------------------------------------
local progDir = ""
if shell and shell.getRunningProgram then
    local ok, p = pcall(shell.getRunningProgram)
    if ok and type(p) == "string" then
        progDir = fs.getDir(p)
        if progDir == ".." then progDir = "" end
    end
end

function T.modulePath(name)
    for _, d in ipairs({ progDir, "", "/" }) do
        local p = (d == "" or d == "/") and (name .. ".lua") or fs.combine(d, name .. ".lua")
        if fs.exists(p) then return p end
    end
    return nil
end

local function loadModule(name, optional)
    local path = T.modulePath(name)
    if not path then
        if optional then return false end
        error(name .. ".lua is missing: run `setup server` again", 0)
    end
    local fn, err = loadfile(path, nil, _ENV)
    if not fn then error(err, 0) end
    fn(T)
    return true
end

for _, m in ipairs({ "tm_db", "tm_radio", "tm_cluster", "tm_ui", "tm_views", "tm_update" }) do loadModule(m) end
-- GPS (CG-3): the optional tm_gps.lua sets T.gps = {wanted(), loop()} and loads tm_gpssolve.lua itself.
loadModule("tm_gps", true)
loadModule("tm_army", true)   -- army coordinator (leader only)

local S = T.S
local TICK = 0.5
local ROLE_CHECK_S = 60

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
function T.detectRoles()
    local r = { ui = pocket ~= nil, gateway = false, link = false, update = false, gps = false,
        member = S.mode == "server" }
    for _, name in ipairs(peripheral.getNames()) do
        local tp = peripheral.getType(name)
        if tp == "monitor" then r.ui = true
        elseif tp == "modem" then
            local ok, w = pcall(peripheral.call, name, "isWireless")
            if ok and w then r.gateway = true else r.link = true end
        end
    end
    r.update = S.mode == "server" and T.update.present()
    r.http = http ~= nil
    r.gps = r.gateway and S.mode == "server" and type(T.gps) == "table" and type(T.gps.wanted) == "function"
        and T.gps.wanted() == true or false
    T.roles = r
    return r
end

function T.rolesText()
    local r, out = T.roles or {}, {}
    for _, k in ipairs({ "ui", "gateway", "link", "update", "gps" }) do if r[k] then out[#out + 1] = k end end
    return #out > 0 and table.concat(out, ",") or "member"
end

-- Roles that need a loop of their own: a change restarts the set of loops.
local function loopSig(r) return tostring(r.update) .. tostring(r.gps) end

-- ---------------------------------------------------------------------------
-- Init / tick / run
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Mesh updates (tmmesh.lua)
-- ---------------------------------------------------------------------------
local IDLE_MS = 30000
S.lastInput = 0

function T.meshStart()
    T.mesh = nil
    local path = T.modulePath("tmmesh")
    if not path or not S.network or not T.crypto then return end
    local fn = loadfile(path, nil, _ENV)
    local okL, Mesh = pcall(fn or error)
    if not okL or type(Mesh) ~= "table" then return end
    T.Mesh = Mesh
    local gpath = T.modulePath("tmguard")
    local guard = nil
    if gpath then
        local gfn = loadfile(gpath, nil, _ENV)
        local okG, g = pcall(gfn or error)
        if okG and type(g) == "table" then guard = g end
    end
    local files = S.mode == "server" and T.update.present() and T.update.dir() or nil
    local okE, E = pcall(function()
        return Mesh.new({ role = S.mode == "pocket" and "pocket" or "server", files = files, key = S.network.key,
            crypto = T.crypto, myId = S.myId, guard = guard,
            send = function(kind, to, body) return T.send(kind, to, body) end,
            log = function(text) T.logLine("update: " .. tostring(text)) end,
            announce = function() T.sendBeacon() end,
            servesServer = function() return T.updateServes and T.updateServes() or false end,
            onBad = function() T.markDirty() end }).init()
    end)
    if okE then T.mesh = E else T.logLine("update: mesh failed to start: " .. tostring(E)) end
end

-- Idle: nobody pressed a key / touched the screen for 30 s and no command waits for an ack.
function T.idle(t)
    t = t or T.now()
    if t - (S.lastInput or 0) < IDLE_MS then return false end
    for _, p in pairs(S.pending) do
        if not p.queued and not p.forwarded then return false end
    end
    return true
end

function T.meshTick(t)
    local E = T.mesh
    if not E then return end
    local ok, err = pcall(E.tick)
    if not ok then S.meshErr = tostring(err) end
    if S.mode == "pocket" and t - (S.lastBeacon or 0) >= 60000 then T.sendBeacon() end
    local okR, r = pcall(E.ready)
    if okR and r and T.idle(t) then
        local okA, applied, info = pcall(E.apply)
        if not okA then
            T.logLine("update: apply error: " .. tostring(applied))
        elseif applied and info and info.reboot then
            T.logLine("update: restarting into the new version")
            T.saveDb()
            os.reboot()
        end
        T.markDirty()
    end
end

function T.init(opts)
    opts = opts or {}
    S.mode = opts.mode or (pocket ~= nil and "pocket" or "server")
    S.myId = os.getComputerID()
    S.boot = T.now()
    S.lastInput = S.boot
    S.cfg = { monitor = opts.monitor or "auto", scale = opts.scale or 0.5 }
    T.loadNetwork()
    T.openModems()
    T.detectRoles()
    T.meshStart()
    if S.mode == "server" then
        T.loadDb()
        T.loadLog()
        T.logLine("server #" .. S.myId .. " started (" .. T.rolesText() .. ")" .. (S.netOk and "" or " (NO MODEM)")
            .. (S.signer and (" network '" .. S.network.name .. "'") or " NO NETWORK: run `setup network`"))
        T.clusterStart()
    else
        T.logLine("pocket #" .. S.myId .. " started")
    end
    S.uis = {}
    if not opts.noDisplay then
        if S.mode == "server" then T.attachMonitor(S.cfg) end
        S.uis[#S.uis + 1] = T.newUI(term.current(), nil)
    end
end

function T.tick()
    local t = T.now()
    T.tickCmds(t)
    T.updateAlerts(t)
    T.clusterTick(t)
    T.tickRadio(t)
    T.meshTick(t)
    if t - S.lastDirtyTick >= 1000 then S.lastDirtyTick = t; T.markDirty() end
end

function T.tickLoop()
    local timer = os.startTimer(TICK)
    while true do
        local _, id = os.pullEvent("timer")
        if id == timer then
            T.tick()
            timer = os.startTimer(TICK)
        end
    end
end

-- Re-check roles every minute and when peripherals change; returns when loops must change.
local function roleWatch(sig)
    return function()
        local timer = os.startTimer(ROLE_CHECK_S)
        while true do
            local ev = { os.pullEvent() }
            local check = false
            if ev[1] == "timer" and ev[2] == timer then
                check = true
                timer = os.startTimer(ROLE_CHECK_S)
            elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
                check = true
            end
            if check then
                local before = T.rolesText()
                local r = T.detectRoles()
                if T.rolesText() ~= before then
                    T.openModems()
                    T.logLine("server #" .. S.myId .. " roles: " .. T.rolesText())
                    T.markDirty()
                end
                if loopSig(r) ~= sig then return end
            end
        end
    end
end

function T.run()
    while true do
        local r = T.detectRoles()
        local loops = { T.netLoop, T.tickLoop }
        if #S.uis > 0 then loops[#loops + 1] = T.uiLoop end
        if S.mode == "server" and r.update then loops[#loops + 1] = T.update.loop end
        if S.mode == "server" and r.gps and T.gps and T.gps.loop then loops[#loops + 1] = T.gps.loop end
        loops[#loops + 1] = roleWatch(loopSig(r))
        parallel.waitForAny(table.unpack(loops))
    end
end

-- Old name for the API table (central_monitor.lua --lib returned M with the same fields).
T.M = T

-- For debugging (lua> TMINER_SERVER.S) and the simulator's scenarios.
if _G then _G.TMINER_SERVER = T end

if args[1] == "--lib" then return T end
do  -- No mining network yet: ask on this computer's screen before starting.
    package.path = "/?.lua;/?;" .. package.path
    local okJ, J = pcall(require, "tmjoin")
    if okJ and J.bootPrompt then J.bootPrompt() end
end
T.init({ monitor = args[1], scale = tonumber(args[2]) })
T.run()
