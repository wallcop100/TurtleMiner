-- Version: 2.0.0
-- TurtleMiner server, update role (a PC with a /files/ folder: the turtles' and relays' files).
-- Mesh updates (tmmesh.lua) do the spreading; this part is the GitHub origin:
--   * pull at boot, every tminer.pull_minutes (default 60) and on "Check now" (`pull_req`
--     from any device; only the lowest-ID live PC with HTTP + /files/ answers, `pull_res`);
--     every newer file that compiles becomes a signed release (tmmesh originate) and spreads
--   * legacy: turtles with the old updater (1.x) still get files the old way once
--     (update_check -> update_manifest, file_get without `sha` -> file), so they can upgrade
--     to the mesh. In a cluster only the lowest-ID PC with /files/ answers.
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
            and not name:match("%.tmp$") and name ~= "relay.lua" and name ~= "relay_startup.lua" then
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

function U.hasPuller() return puller() ~= false end

-- Pull from GitHub into the mesh. Returns ok, number of new releases, err.
function U.pull()
    local p = puller()
    local E = T.mesh
    if not p then return false, 0, "github_pull.lua missing" end
    if not E then return false, 0, "no mesh (network or tmmesh.lua missing)" end
    local log = function(s) T.logLine("update: " .. s) end
    E.ensureScan(function() sleep(0) end)
    local ok, list, err = pcall(p.fetchNewer, E.names(), function(name) return E.heldVersion(name) end, log)
    if not ok then log("pull error: " .. tostring(list)); return false, 0, tostring(list) end
    local n, names = 0, {}
    for _, f in ipairs(list) do
        local okO, why = E.originate(f.name, f.body)
        if okO then
            n = n + 1
            names[#names + 1] = (T.Mesh and T.Mesh.shortName(f.name) or f.name) .. " " .. f.version
        elseif why ~= "not newer" then
            log("pull: " .. f.name .. " " .. f.version .. ": " .. tostring(why))
        end
    end
    U.lastPull = { at = T.now(), n = n, err = err }
    if n > 0 then
        log("GitHub: " .. table.concat(names, ", "))
        E.announce()
    elseif err then
        log("GitHub: " .. err)
    end
    T.markDirty()
    return true, n, err
end

-- Loop for the update role: pull at start, every tminer.pull_minutes (0 = boot only) and
-- when asked (Check now / pull_req).
function U.loop()
    if not U.pulledAtBoot then
        U.pulledAtBoot = true
        U.pull()
    end
    local p = puller()
    local m = p and p.interval and p.interval() or 0
    local nextAt = m > 0 and (T.now() + m * 60000) or math.huge
    while true do
        sleep(1)
        local want = U.pullWanted
        if want or T.now() >= nextAt then
            U.pullWanted = nil
            local ok, n, err = U.pull()
            if m > 0 then nextAt = T.now() + m * 60000 end
            if want then
                if want.from == S.myId then
                    S.pullMsg = ok and ("pulled: " .. n .. " new file(s)" .. (err and (" (" .. err .. ")") or "")) or ("pull failed: " .. tostring(err))
                    T.markDirty()
                else
                    T.send("pull_res", want.from, { ok = ok, n = n, err = err })
                end
            end
        end
    end
end

return T
