-- Version: 1.4.0
-- Pulls newer TurtleMiner files from GitHub into the update server's folder
-- (and the server's own programs). Used by update_server at boot and every
-- tminer.pull_minutes (default 60, 0 = boot only).
--
-- Settings:
--   tminer.repo_base     raw GitHub base URL (default: this project's branch)
--   tminer.pull_minutes  minutes between pulls after boot (0 = boot only)
--   tminer.auto_pull     false disables pulling entirely
--
-- A file is replaced only when GitHub has a strictly newer "-- Version:" first
-- line and the new content compiles. Writes go to a .tmp file, then move.
-- Mesh updates (tm_update.lua): M.fetchNewer(names, heldVersion, log) only downloads; the
-- caller signs the new files as releases (tmmesh originate) and the mesh spreads them. The
-- file lists come from tmmesh.SETS; M.MINER / M.SERVER below serve the legacy M.pull only.

local M = {}

M.DEFAULT_BASE = "https://raw.githubusercontent.com/wallcop100/TurtleMiner/main/"

M.MINER = { "config.lua", "state.lua", "nav.lua", "inv.lua", "mine.lua", "net.lua",
            "miner.lua", "updater.lua", "install.lua", "startup.lua",
            "tmcrypto.lua", "tmwords.lua", "tmjoin.lua" }

-- Server programs: repo path -> local path. Only replaced if already present (so a
-- monitor-less update server doesn't suddenly get a monitor). The third field lists files
-- that need this one: it is installed when any of them is present (tminer_server and its
-- modules come with the central_monitor launcher that now runs them).
local NEEDS_SERVER = { "central_monitor.lua", "tminer_server.lua", "tminer_startup.lua", "monitor_startup.lua" }
-- Mining network modules (signing, join): every computer running our programs needs them.
local NEEDS_NET = { "central_monitor.lua", "tminer_server.lua", "tminer_startup.lua", "monitor_startup.lua",
    "relay.lua", "update_server.lua" }
M.SERVER = {
    { "servers/tm_db.lua", "tm_db.lua", NEEDS_SERVER },
    { "servers/tm_radio.lua", "tm_radio.lua", NEEDS_SERVER },
    { "servers/tm_cluster.lua", "tm_cluster.lua", NEEDS_SERVER },
    { "servers/tm_ui.lua", "tm_ui.lua", NEEDS_SERVER },
    { "servers/tm_views.lua", "tm_views.lua", NEEDS_SERVER },
    { "servers/tm_update.lua", "tm_update.lua", NEEDS_SERVER },
    { "servers/tm_gps.lua", "tm_gps.lua", NEEDS_SERVER },
    { "servers/tm_gpssolve.lua", "tm_gpssolve.lua", NEEDS_SERVER },
    { "servers/tminer_server.lua", "tminer_server.lua", NEEDS_SERVER },
    { "servers/central_monitor.lua", "central_monitor.lua" },
    { "servers/update_server/update_server.lua", "update_server.lua" },
    { "servers/update_server/github_pull.lua", "github_pull.lua" },
    { "servers/startup.lua", "monitor_startup.lua" },
    { "servers/startup.lua", "tminer_startup.lua" },
    { "servers/relay.lua", "relay.lua" },
    { "miner/tmcrypto.lua", "tmcrypto.lua", NEEDS_NET },
    { "miner/tmwords.lua", "tmwords.lua", NEEDS_NET },
    { "miner/tmjoin.lua", "tmjoin.lua", NEEDS_NET },
}

local function wanted(p)
    if fs.exists(p[2]) then return true end
    for _, other in ipairs(p[3] or {}) do if fs.exists(other) then return true end end
    return false
end

local function versionOf(text)
    if type(text) ~= "string" then return nil end
    local line = text:match("^[^\n]*")
    local a, b, c = line:match("^%s*%-%-%s*[Vv]ersion:%s*(%d+)%.(%d+)%.(%d+)")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }, a .. "." .. b .. "." .. c
end

local function newer(x, y)
    if not y then return true end
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return false
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

local function writeAtomic(path, content)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local tmp = path .. ".tmp"
    if fs.exists(tmp) then fs.delete(tmp) end
    local f = fs.open(tmp, "w")
    if not f then return false end
    f.write(content)
    f.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
end

local function fetch(url)
    local ok, h = pcall(http.get, url)
    if not ok or not h then return nil end
    local body = h.readAll()
    h.close()
    return body
end

-- Returns: changed (list of local paths), serverChanged (bool), err (string|nil)
function M.pull(filesDir, log)
    log = log or print
    if settings and settings.get("tminer.auto_pull") == false then return {}, false, "disabled" end
    if not http then return {}, false, "HTTP API disabled" end
    local base = (settings and settings.get("tminer.repo_base")) or M.DEFAULT_BASE
    if base:sub(-1) ~= "/" then base = base .. "/" end
    if filesDir:sub(-1) ~= "/" then filesDir = filesDir .. "/" end

    local jobs = {}
    for _, f in ipairs(M.MINER) do jobs[#jobs + 1] = { "miner/" .. f, filesDir .. f, false } end
    for _, p in ipairs(M.SERVER) do
        if wanted(p) then jobs[#jobs + 1] = { p[1], p[2], true } end
    end

    -- Fetch and check everything first. Server programs go all-or-nothing: a new launcher
    -- without its modules would not start.
    local failed, serverFailed = 0, false
    for _, j in ipairs(jobs) do
        local body = fetch(base .. j[1])
        local nv, nvs = versionOf(body)
        if not body or not nv then
            failed = failed + 1
            if j[3] then serverFailed = true end
        elseif not load(body, "=" .. j[1], "t", {}) then
            log("pull: " .. j[1] .. " v" .. nvs .. " does not compile, skipped")
            failed = failed + 1
            if j[3] then serverFailed = true end
        else
            local cv, cvs = versionOf(readFile(j[2]))
            if newer(nv, cv) then j.body, j.nvs, j.cvs = body, nvs, cvs end
        end
    end
    if serverFailed then log("pull: server programs not updated (a file is missing upstream)") end

    local changed, serverChanged = {}, false
    for _, j in ipairs(jobs) do
        if j.body and not (j[3] and serverFailed) and writeAtomic(j[2], j.body) then
            changed[#changed + 1] = j[2]
            if j[3] then serverChanged = true end
            log(("pull: %s %s -> %s"):format(j[2], j.cvs or "missing", j.nvs))
        end
    end
    local err = nil
    if failed > 0 then err = failed .. " file(s) could not be fetched" end
    return changed, serverChanged, err
end

-- Newer files on GitHub for these repo paths. heldVersion(name) -> "x.y.z" or nil.
-- Returns list of {name, body, version}, err (string or nil).
function M.fetchNewer(names, heldVersion, log)
    log = log or print
    if settings and settings.get("tminer.auto_pull") == false then return {}, "disabled" end
    if not http then return {}, "HTTP API disabled" end
    local base = (settings and settings.get("tminer.repo_base")) or M.DEFAULT_BASE
    if base:sub(-1) ~= "/" then base = base .. "/" end
    local out, failed = {}, 0
    for _, name in ipairs(names) do
        local body = fetch(base .. name)
        local nv, nvs = versionOf(body)
        if not body or not nv then
            failed = failed + 1
        else
            local cv = versionOf("-- Version: " .. tostring(heldVersion(name) or "0.0.0"))
            if not heldVersion(name) or newer(nv, cv) then
                if load(body, "=" .. name, "t", {}) then
                    out[#out + 1] = { name = name, body = body, version = nvs }
                else
                    log("pull: " .. name .. " v" .. nvs .. " does not compile, skipped")
                end
            end
        end
    end
    return out, failed > 0 and (failed .. " file(s) could not be fetched") or nil
end

function M.interval()
    local m = settings and tonumber(settings.get("tminer.pull_minutes"))
    if m == nil then m = 60 end
    return m
end

return M
