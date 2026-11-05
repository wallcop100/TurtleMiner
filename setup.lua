-- Version: 1.4.3
-- One-shot downloader. Usage (in CC, needs the HTTP API enabled):
--   wget run <BASE>/setup.lua server    -- any server PC: tminer_server + update files (/files/)
--   wget run <BASE>/setup.lua monitor   -- server PC without update files (same program)
--   wget run <BASE>/setup.lua pocket    -- pocket computer
--   wget run <BASE>/setup.lua turtle    -- turtle, without an update server
--   wget run <BASE>/setup.lua relay     -- relay computer (any modems: ender, basic, wired)
--   setup network                       -- change this device's mining network later
--   setup network --to-disk             -- copy the network to a floppy in a drive next to it
-- Every role joins a mining network at the end (required; docs/MESH_UPDATE_PLAN.md section 1):
-- create one, type the 4 words of an existing one, take it from a disk, or ask a server UI to
-- approve. Without questions: --create [name] | --join <4 words> [--name n] | --disk | --approve.
-- Every server PC runs the same program (tminer_server); it finds its roles itself (UI with a
-- monitor, radio gateway with a wireless/ender modem, cluster link with a wired modem, update
-- server with /files/) and the PCs form one cluster with one leader.
-- BASE = https://raw.githubusercontent.com/wallcop100/TurtleMiner/<branch>

local BRANCH = "main"
local BASE = "https://raw.githubusercontent.com/wallcop100/TurtleMiner/" .. BRANCH .. "/"

local MINER = { "config.lua", "state.lua", "nav.lua", "inv.lua", "mine.lua", "net.lua",
                "miner.lua", "updater.lua", "install.lua", "startup.lua",
                "tmcrypto.lua", "tmwords.lua", "tmjoin.lua" }
-- Mining network modules: every device gets them (from miner/).
local NETMODS = { "tmcrypto.lua", "tmwords.lua", "tmjoin.lua" }
-- tminer_server and its modules (central_monitor = compatibility launcher for old startups)
local SERVER = { "tminer_server.lua", "tm_db.lua", "tm_radio.lua", "tm_cluster.lua", "tm_ui.lua",
                 "tm_views.lua", "tm_update.lua", "tm_gps.lua", "tm_gpssolve.lua", "central_monitor.lua" }

local function get(src, dst)
    local h, err = http.get(BASE .. src)
    if not h then
        printError("failed: " .. src .. " (" .. tostring(err) .. ")")
        return false
    end
    local body = h.readAll()
    h.close()
    local dir = fs.getDir(dst)
    if dir ~= "" then
        if fs.exists(dir) and not fs.isDir(dir) then
            -- A file is sitting where the folder should be: move it aside.
            local aside = dir .. ".old"
            if fs.exists(aside) then fs.delete(aside) end
            fs.move(dir, aside)
            print("moved file " .. dir .. " to " .. aside .. " (a folder is needed there)")
        end
        if not fs.exists(dir) then fs.makeDir(dir) end
    end
    if fs.isDir(dst) then
        printError("failed: " .. dst .. " is a folder; delete or rename it and run setup again")
        return false
    end
    if fs.isReadOnly(dst) then
        printError("failed: " .. dst .. " is read-only")
        return false
    end
    local free = fs.getFreeSpace(dir ~= "" and dir or "/")
    local tmp = dst .. ".tmp"
    local f, ferr = fs.open(tmp, "w")
    if not f then
        printError(("failed: can't write %s (%s). Free space: %s bytes, file needs %d.")
            :format(dst, tostring(ferr), tostring(free), #body))
        if type(free) == "number" and free < #body + 1024 then
            printError("The computer's disk is full: delete old files (ls, rm) and run setup again.")
        end
        return false
    end
    f.write(body)
    f.close()
    if fs.exists(dst) then fs.delete(dst) end
    fs.move(tmp, dst)
    print("ok  " .. dst)
    return true
end

local argv = { ... }
local role = argv[1]
local netFlags = {}
for i = 2, #argv do netFlags[#netFlags + 1] = argv[i] end
package.path = "/?.lua;/?;" .. package.path

-- Create or join the mining network (role "network": change it). Returns true when done.
local function network(change)
    local okJ, J = pcall(require, "tmjoin")
    if not okJ then printError("network: " .. tostring(J)); return false end
    local o = J.parseArgs(netFlags)
    if o.toDisk then
        local okD, err = J.toDisk()
        print(okD and "Network copied to the disk." or ("failed: " .. tostring(err)))
        return okD
    end
    local explicit = o.join ~= nil or o.create ~= nil or o.disk or o.approve
    o.change = change or explicit
    o.auto = explicit
    local n, how = J.ensure(o)
    if not n then printError("No mining network: " .. tostring(how)); return false end
    print("Mining network '" .. n.name .. "'" .. (how == "existing" and "" or (" (" .. how .. ")")))
    return true
end

if role == "network" then
    for _, f in ipairs(NETMODS) do
        if not fs.exists(f) then
            if not http then error(f .. " is missing and the HTTP API is disabled", 0) end
            get("miner/" .. f, f)
        end
    end
    if http and not fs.exists("setup.lua") then get("setup.lua", "setup.lua") end
    if network(true) then print("Reboot to use it.") end
    return
end

if not http then error("HTTP API is disabled in the CC config", 0) end

local ok = true
local function writeText(path, text)
    if fs.isDir(path) then
        printError("failed: " .. path .. " is a folder; delete or rename it and run setup again")
        ok = false
        return
    end
    local h, err = fs.open(path, "w")
    if not h then
        printError("failed: can't write " .. path .. " (" .. tostring(err) .. "), free space "
            .. tostring(fs.getFreeSpace("/")) .. " bytes")
        ok = false
        return
    end
    h.write(text)
    h.close()
    print("ok  " .. path)
end

local function all(list) for _, p in ipairs(list) do ok = get(p[1], p[2]) and ok end end
local function writeStartup(text, what)
    writeText("startup.lua", text)
end

if role == "server" or role == "monitor" or role == "pocket" then
    for _, f in ipairs(SERVER) do all({ { "servers/" .. f, f } }) end
    for _, f in ipairs(NETMODS) do all({ { "miner/" .. f, f } }) end
    all({ { "servers/update_server/github_pull.lua", "github_pull.lua" } })
    if role == "server" then
        for _, f in ipairs(MINER) do all({ { "miner/" .. f, "files/" .. f } }) end
    end
    -- One program, restarted on a crash; roles are detected at boot and every minute.
    all({ { "servers/startup.lua", "tminer_startup.lua" } })
    -- Old installs ran update_server next to the monitor: tminer_server does both now.
    for _, old in ipairs({ "monitor_startup.lua", "update_server.lua" }) do
        if fs.exists(old) then fs.delete(old); print("del " .. old) end
    end
    writeStartup('shell.run("tminer_startup")\n', "tminer_server")
elseif role == "relay" then
    all({ { "servers/relay.lua", "relay.lua" } })
    for _, f in ipairs(NETMODS) do all({ { "miner/" .. f, f } }) end
    writeStartup('while true do\n'
        .. '    local ok, err = pcall(shell.run, "relay")\n'
        .. '    print("relay stopped: " .. tostring(err))\n'
        .. '    sleep(5)\n'
        .. 'end\n', "relay")
elseif role == "turtle" then
    for _, f in ipairs(MINER) do all({ { "miner/" .. f, f } }) end
else
    print("usage: setup server|monitor|pocket|turtle|relay|network [--create [name] | --join <4 words> | --disk | --approve]")
    return
end

if not ok then print("Some files failed; check the errors above."); return end
-- Keep a copy of setup itself, so `setup network` (and re-running setup) works later.
if http then get("setup.lua", "setup.lua") end
if not network(false) then print("Not finished: no mining network. Run `setup network`."); return end
if role == "turtle" then print("Now run: install") end
print("Done. Reboot to start.")
