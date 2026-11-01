-- Version: 1.0.0
-- TurtleMiner server, update role (a PC with a /files/ folder): serves the files in it to
-- turtles (update_check -> update_manifest, file_get -> file; docs/PROTOCOL.md) and pulls
-- newer files from GitHub at boot and every tminer.pull_minutes (github_pull.lua, optional).
-- Same behaviour as the stand-alone update_server.lua. In a cluster only the lowest-ID PC
-- with /files/ answers (T.updateServes in tm_cluster.lua), so a turtle gets one reply.
local T = ...
local S = T.S

local U = { checks = 0, served = 0 }
T.update = U

function U.dir()
    local d = (settings and settings.get and settings.get("tminer.update_dir")) or "/files/"
    if d:sub(-1) ~= "/" then d = d .. "/" end
    return d
end

-- Role check for tminer_server: this PC has an update folder.
function U.present()
    local d = U.dir()
    return fs.exists(d) and fs.isDir(d)
end

local function versionOf(line)
    if type(line) ~= "string" then return nil end
    return line:match("^%s*%-%-%s*[Vv]ersion:%s*(%d+%.%d+%.%d+)")
end

local function safeName(n)
    return type(n) == "string" and #n > 0 and #n <= 64
        and not n:find("[/\\:]") and not n:find("%.%.")
end

local function roleDir(role)
    local d = U.dir()
    if safeName(role) and fs.isDir(d .. role) then return d .. role .. "/" end
    return d
end

-- Built fresh on every request, so dropping in a new file needs no restart.
function U.manifest(role)
    local dir = roleDir(role)
    local list = {}
    if not fs.isDir(dir) then return list, dir end
    for _, name in ipairs(fs.list(dir)) do
        local path = dir .. name
        if not fs.isDir(path) and safeName(name) and not name:match("%.bak$") and not name:match("%.new$")
            and not name:match("%.tmp$") then
            local f = fs.open(path, "r")
            if f then
                local v = versionOf(f.readLine())
                f.close()
                list[#list + 1] = { name = name, version = v or "0.0.0" }
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list, dir
end

function T.updateMessage(msg)
    if not (T.updateServes and T.updateServes()) then return end
    if msg.to ~= "server" and msg.to ~= S.myId then return end
    local role = type(msg.role) == "string" and msg.role or "miner"
    if msg.kind == "update_check" then
        local files = U.manifest(role)
        U.checks = U.checks + 1
        T.send("update_manifest", msg.from, { files = files })
        return
    end
    local name, content, version, err = msg.name, nil, nil, nil
    if not safeName(name) then
        err = "bad name"
    else
        local path = roleDir(role) .. name
        if fs.exists(path) and not fs.isDir(path) then
            content = T.readFile(path)
            version = versionOf(content and content:match("^([^\n]*)")) or "0.0.0"
            if not content then err = "read failed" end
        else
            err = "not found"
        end
    end
    T.send("file", msg.from, { name = name, version = version, content = content, err = err })
    if content then U.served = U.served + 1 end
end

-- GitHub pull (github_pull.lua next to the program; optional). New server programs: one
-- guarded reboot to run them.
local function puller()
    if U.puller ~= nil then return U.puller end
    U.puller = false
    local path = T.modulePath and T.modulePath("github_pull")
    if path then
        local fn = loadfile(path, nil, _ENV)
        local ok, m = pcall(fn or error)
        if ok and type(m) == "table" then U.puller = m end
    end
    return U.puller
end

function U.pull()
    local p = puller()
    if not p then return end
    local log = function(s) T.logLine("update: " .. s) end
    local ok, changed, serverChanged, err = pcall(p.pull, U.dir(), log)
    if not ok then log("pull error: " .. tostring(changed)) return end
    if err then log(err) end
    if #changed > 0 then log(#changed .. " file(s) updated from GitHub") end
    if serverChanged then
        local guard = ".pull_reboot"
        local last = tonumber(T.readFile(guard) or "")
        if not last or os.epoch("utc") - last > 120000 then
            T.writeAtomic(guard, tostring(os.epoch("utc")))
            log("server programs updated, rebooting")
            sleep(1)
            os.reboot()
        end
    end
end

-- Loop for the update role: pull at start, then every tminer.pull_minutes (0 = boot only).
function U.loop()
    if not U.pulledAtBoot then
        U.pulledAtBoot = true
        U.pull()
    end
    local p = puller()
    local m = p and p.interval and p.interval() or 0
    while true do
        if m <= 0 then sleep(3600) else sleep(m * 60); U.pull() end
    end
end

return T
