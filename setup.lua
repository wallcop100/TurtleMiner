-- Version: 1.2.0
-- One-shot downloader. Usage (in CC, needs the HTTP API enabled):
--   wget run <BASE>/setup.lua server    -- update server + monitor on one computer
--   wget run <BASE>/setup.lua monitor   -- monitor only
--   wget run <BASE>/setup.lua pocket    -- pocket computer
--   wget run <BASE>/setup.lua turtle    -- turtle, without an update server
--   wget run <BASE>/setup.lua relay     -- relay computer (any modems: ender, basic, wired)
-- BASE = https://raw.githubusercontent.com/wallcop100/TurtleMiner/<branch>

local BRANCH = "claude/vigilant-pasteur-g2krss"
local BASE = "https://raw.githubusercontent.com/wallcop100/TurtleMiner/" .. BRANCH .. "/"

local MINER = { "config.lua", "state.lua", "nav.lua", "inv.lua", "mine.lua", "net.lua",
                "miner.lua", "updater.lua", "install.lua", "startup.lua" }

local function get(src, dst)
    local h, err = http.get(BASE .. src)
    if not h then
        printError("failed: " .. src .. " (" .. tostring(err) .. ")")
        return false
    end
    local body = h.readAll()
    h.close()
    local dir = fs.getDir(dst)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(dst, "w")
    f.write(body)
    f.close()
    print("ok  " .. dst)
    return true
end

local role = ({ ... })[1]
if not http then error("HTTP API is disabled in the CC config", 0) end

local ok = true
local function all(list) for _, p in ipairs(list) do ok = get(p[1], p[2]) and ok end end

if role == "server" or role == "monitor" then
    all({ { "servers/central_monitor.lua", "central_monitor.lua" } })
    if role == "server" then
        all({ { "servers/update_server/update_server.lua", "update_server.lua" } })
        all({ { "servers/update_server/github_pull.lua", "github_pull.lua" } })
        for _, f in ipairs(MINER) do all({ { "miner/" .. f, "files/" .. f } }) end
        -- One startup that runs both the monitor (with crash restart) and the update server.
        all({ { "servers/startup.lua", "monitor_startup.lua" } })
        local s = fs.open("startup.lua", "w")
        s.write('parallel.waitForAny(\n'
            .. '    function() shell.run("update_server") end,\n'
            .. '    function() shell.run("monitor_startup") end)\n')
        s.close()
        print("ok  startup.lua (monitor + update server)")
    else
        all({ { "servers/startup.lua", "startup.lua" } })
    end
elseif role == "pocket" then
    all({ { "servers/central_monitor.lua", "central_monitor.lua" } })
    local s = fs.open("startup.lua", "w")
    s.write('shell.run("central_monitor")\n')
    s.close()
elseif role == "relay" then
    all({ { "servers/relay.lua", "relay.lua" } })
    local s = fs.open("startup.lua", "w")
    s.write('while true do\n'
        .. '    local ok, err = pcall(shell.run, "relay")\n'
        .. '    print("relay stopped: " .. tostring(err))\n'
        .. '    sleep(5)\n'
        .. 'end\n')
    s.close()
    print("ok  startup.lua (relay)")
elseif role == "turtle" then
    for _, f in ipairs(MINER) do all({ { "miner/" .. f, f } }) end
    print("Now run: install")
else
    print("usage: setup server|monitor|pocket|turtle|relay")
    return
end

print(ok and "Done. Reboot to start." or "Some files failed; check the errors above.")
