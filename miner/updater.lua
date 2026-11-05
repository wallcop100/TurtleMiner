-- Version: 2.0.0
-- TurtleMiner updater: the command-line face of the mesh updates (tmmesh.lua, tmguard.lua;
-- docs/MESH_UPDATE_PLAN.md). Runs on every device (turtles, server PCs, pockets, relays).
--
-- Module:  local updated, info = require("updater").run(opts)
--   opts.mesh       a running tmmesh engine (the miner's): install what it fetched; with
--                   opts.wait > 0 ask the network first and wait up to that many seconds
--   opts.stagedOnly install what the mesh fetched earlier, no network (startup at boot)
--   (neither)       ask the network now (`list_get` to the update server), fetch, install
--   opts.check      only report; opts.timeout (s, default 20); opts.log(text)
--   Never reboots; info.reboot says whether running programs changed.
-- CLI:     updater            fetch newer files over the mesh and install them
--          updater --check    only list what would change
--          updater --pull     ask the update PC (HTTP + /files/) to pull from GitHub now;
--                             the result spreads to every device by itself
-- Only files with a release note signed by this device's mining network are installed, after
-- their SHA-256 and load() check. No network: no update.

local M = {}

local PROTOCOL = "TMINER"
local MAX_HOPS = 4
local BOOT = os.epoch and os.epoch("utc") or 0
local seq = math.random(100000, 999999) * 1000
M.PROTOCOL = PROTOCOL
M.rejected = 0
M.DEFAULT_TIMEOUT = 20

local function loadMod(name)
    if require then
        local ok, m = pcall(require, name)
        if ok and type(m) == "table" then return m end
    end
    for _, p in ipairs({ name .. ".lua", "/" .. name .. ".lua" }) do
        if fs and fs.exists(p) then
            local fn = loadfile(p, nil, _ENV)
            local ok, m = pcall(fn or error)
            if ok and type(m) == "table" then return m end
        end
    end
    return nil
end

-- ---------------------------------------------------------------- versions
function M.versionOf(text)
    if type(text) ~= "string" then return nil end
    local first = text:match("^([^\n]*)") or ""
    return first:match("^%s*%-%-%s*[Vv]ersion:%s*(%d+%.%d+%.%d+)")
end

function M.fileVersion(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local line = f.readLine()
    f.close()
    return M.versionOf(line)
end

local function parts(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end
function M.compare(a, b)
    local pa, pb = parts(a) or { 0, 0, 0 }, parts(b) or { 0, 0, 0 }
    for i = 1, 3 do
        if pa[i] < pb[i] then return -1 end
        if pa[i] > pb[i] then return 1 end
    end
    return 0
end

function M.validate(name, text)
    if type(text) ~= "string" or #text == 0 then return false, "empty" end
    local fn, err = load(text, "=" .. name, "t", {})
    if not fn then return false, tostring(err) end
    return true
end

-- What kind of device this is (which file set it holds).
function M.role()
    if turtle then return "turtle", nil end
    if pocket then return "pocket", nil end
    if fs.exists("relay.lua") and not fs.exists("tminer_server.lua") then return "relay", nil end
    local d = (settings and settings.get and settings.get("tminer.update_dir")) or "/files/"
    d = d:gsub("^/+", "")
    if d:sub(-1) ~= "/" then d = d .. "/" end
    if fs.isDir(d) then return "server", d end
    return "server", nil
end

-- ---------------------------------------------------------------- network
local function openModems()
    local opened, any = {}, false
    if not peripheral or not rednet then return opened, false end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if rednet.isOpen(name) then any = true
            elseif pcall(rednet.open, name) and rednet.isOpen(name) then
                any = true
                opened[#opened + 1] = name
            end
        end
    end
    return opened, any
end
local function closeModems(opened) for _, n in ipairs(opened) do pcall(rednet.close, n) end end

local function newLink(signer)
    local L = {}
    function L.send(kind, to, body)
        seq = seq + 1
        local msg = {}
        for k, v in pairs(body or {}) do msg[k] = v end
        msg.v, msg.kind, msg.from, msg.to = 1, kind, os.getComputerID(), to
        msg.boot, msg.seq, msg.ts, msg.hops = BOOT, seq, os.epoch("utc"), 0
        signer.sign(msg)
        pcall(rednet.broadcast, msg, PROTOCOL)
        return msg
    end
    -- Next signed TMINER message for us (or "all"); nil on timeout.
    function L.receive(timeout)
        local deadline = os.clock() + timeout
        while true do
            local left = deadline - os.clock()
            if left <= 0 then return nil end
            local ok, id, msg = pcall(rednet.receive, PROTOCOL, math.min(left, 1))
            if ok and id ~= nil and type(msg) == "table" and msg.v == 1 and type(msg.kind) == "string"
                and (type(msg.hops) ~= "number" or msg.hops <= MAX_HOPS) then
                if not signer.check(msg, os.epoch("utc")) then
                    M.rejected = M.rejected + 1
                else
                    return msg
                end
            elseif not ok then
                return nil
            end
        end
    end
    return L
end

local function engine(C, n, link, log)
    local Mesh = loadMod("tmmesh")
    if not Mesh then return nil, "tmmesh.lua missing" end
    local role, files = M.role()
    local E = Mesh.new({ role = role, files = files, key = n and n.key or nil, crypto = C,
        send = link and link.send or nil, log = log, myId = os.getComputerID() })
    E.init()
    return E, Mesh
end

-- ---------------------------------------------------------------- run
local function finish(E, opts, info)
    local log = opts.log or function() end
    info.pending = E.pending()
    if #info.pending == 0 and not E.ready() then
        info.reason = info.reason or "up to date"
        return false, info
    end
    if opts.check then
        info.reason = "check only"
        for _, p in ipairs(info.pending) do
            log(("%s %s -> %s%s"):format(p.name, p.have or "missing", p.want, p.staged and " (fetched)" or ""))
        end
        return false, info
    end
    if not E.ready() then
        info.reason = info.reason or ("not all files fetched (" .. #E.want() .. " missing)")
        return false, info
    end
    local ok, r = E.apply()
    info.files = {}
    for _, f in ipairs(r and r.files or {}) do info.files[#info.files + 1] = f end
    info.reboot = r and r.reboot
    info.reason = r and r.reason
    if ok then log("installed " .. #info.files .. " file(s)") end
    return ok and #info.files > 0, info
end

function M.run(opts)
    opts = opts or {}
    local log = opts.log or function() end
    local info = { files = {} }
    M.rejected = 0
    if opts.mesh then
        local E = opts.mesh
        local waited = 0
        if (opts.wait or 0) > 0 and not E.ready() then
            E.checkNow("server")
            while waited < opts.wait and not E.ready() do
                sleep(1)
                waited = waited + 1
                if waited >= 3 and E.idle() and #E.want() == 0 then break end
            end
        end
        return finish(E, opts, info)
    end
    local C = loadMod("tmcrypto")
    local n = C and C.loadNetwork()
    if opts.stagedOnly then
        -- no key: a crash-rollback record stays for the networked engine (it signs + sends the mark)
        local okE, E = pcall(engine, C, nil, nil, log)
        if not okE or not E then info.reason = tostring(E or "no mesh"); return false, info end
        E.ensureScan(function() sleep(0) end)
        if not E.ready() then info.reason = "nothing fetched"; return false, info end
        return finish(E, opts, info)
    end
    if not n then info.reason = "no mining network (run install --network / setup network)"; return false, info end
    if not rednet then info.reason = "no rednet"; return false, info end
    local opened, any = openModems()
    if not any then info.reason = "no modem"; return false, info end
    local ok, a, b = pcall(function()
        local link = newLink(C.signer(n))
        local E = engine(C, n, link, log)
        if not E then return false, { files = {}, reason = "tmmesh.lua missing" } end
        E.ensureScan(function() sleep(0) end)
        E.checkNow("server")
        local deadline = os.clock() + (opts.timeout or M.DEFAULT_TIMEOUT)
        local gotList = false
        while os.clock() < deadline do
            local msg = link.receive(1)
            if msg and (msg.to == os.getComputerID() or msg.to == "all") then
                if msg.kind == "files_list" then gotList = true end
                E.handle(msg)
            end
            E.tick()
            if gotList and E.idle() and (E.ready() or #E.want() == 0) then break end
        end
        if not gotList then
            info.reason = "no update server answered" .. (M.rejected > 0 and (" (" .. M.rejected .. " unsigned/foreign replies ignored)") or "")
        end
        return finish(E, opts, info)
    end)
    closeModems(opened)
    if not ok then return false, { files = {}, reason = "updater error: " .. tostring(a) } end
    return a, b
end

-- Ask the update PC to pull from GitHub now. Returns ok, text.
function M.pull(opts)
    opts = opts or {}
    local C = loadMod("tmcrypto")
    local n = C and C.loadNetwork()
    if not n then return false, "no mining network" end
    local opened, any = openModems()
    if not any then return false, "no modem" end
    local link = newLink(C.signer(n))
    link.send("pull_req", "server", {})
    local deadline = os.clock() + (opts.timeout or 60)
    local res
    while os.clock() < deadline do
        local msg = link.receive(1)
        if msg and msg.kind == "pull_res" and msg.to == os.getComputerID() then res = msg; break end
    end
    closeModems(opened)
    if not res then return false, "no update PC with HTTP answered (needs a server PC with /files/ and HTTP)" end
    if res.ok == false then return false, "#" .. tostring(res.from) .. ": " .. tostring(res.err) end
    return true, "#" .. tostring(res.from) .. " pulled from GitHub: " .. tostring(res.n or 0) .. " new file(s)"
        .. ((res.n or 0) > 0 and "; they spread to every device by themselves" or "")
end

-- ---------------------------------------------------------------- CLI
local first = ...
if first == nil or (type(first) == "string" and first:sub(1, 1) == "-") then
    local args = { ... }
    local checkOnly, pull = false, false
    for _, a in ipairs(args) do
        if a == "--check" then checkOnly = true
        elseif a == "--pull" then pull = true
        elseif a == "--help" or a == "-h" then
            print("Usage: updater [--check | --pull]")
            return M
        end
    end
    if pull then
        local ok, text = M.pull({ timeout = 60 })
        print((ok and "" or "No pull: ") .. text)
        return M
    end
    local updated, info = M.run({ check = checkOnly, log = print })
    if updated then
        print("Updated: " .. table.concat(info.files, ", "))
        print("Reboot to use the new version.")
    elseif checkOnly and info.pending and #info.pending > 0 then
        print(#info.pending .. " file(s) can be updated. Run 'updater' to install.")
    else
        print("No update: " .. tostring(info.reason))
    end
end

return M
