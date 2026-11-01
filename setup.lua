-- Version: 1.2.1
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

local role = ({ ... })[1]
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

if role == "server" or role == "monitor" then
    all({ { "servers/central_monitor.lua", "central_monitor.lua" } })
    if role == "server" then
        all({ { "servers/update_server/update_server.lua", "update_server.lua" } })
        all({ { "servers/update_server/github_pull.lua", "github_pull.lua" } })
        for _, f in ipairs(MINER) do all({ { "miner/" .. f, "files/" .. f } }) end
        -- One startup that runs both the monitor (with crash restart) and the update server.
        all({ { "servers/startup.lua", "monitor_startup.lua" } })
        writeText("startup.lua", 'parallel.waitForAny(\n'
            .. '    function() shell.run("update_server") end,\n'
            .. '    function() shell.run("monitor_startup") end)\n')
    else
        all({ { "servers/startup.lua", "startup.lua" } })
    end
elseif role == "pocket" then
    all({ { "servers/central_monitor.lua", "central_monitor.lua" } })
    writeText("startup.lua", 'shell.run("central_monitor")\n')
elseif role == "relay" then
    all({ { "servers/relay.lua", "relay.lua" } })
    writeText("startup.lua", 'while true do\n'
        .. '    local ok, err = pcall(shell.run, "relay")\n'
        .. '    print("relay stopped: " .. tostring(err))\n'
        .. '    sleep(5)\n'
        .. 'end\n')
elseif role == "turtle" then
    for _, f in ipairs(MINER) do all({ { "miner/" .. f, f } }) end
    print("Now run: install")
else
    print("usage: setup server|monitor|pocket|turtle|relay")
    return
end

print(ok and "Done. Reboot to start." or "Some files failed; check the errors above.")
