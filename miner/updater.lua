-- Version: 1.0.1
-- TurtleMiner updater. Talks to the update server over rednet protocol "TMINER"
-- (update_check / update_manifest / file_get / file, see docs/PROTOCOL.md).
--
-- Module:  local updated, info = require("updater").run(opts)
-- CLI:     updater            install newer / missing files
--          updater --check    only list what would change
--
-- Rules: never reboots, never rewrites an existing startup.lua, never errors on
-- bad replies or a missing server. Every file is written to <name>.new and
-- checked with load() before anything is replaced; the old file is kept as
-- <name>.bak. If any file fails, nothing is replaced.

local M = {}

local PROTOCOL = "TMINER"
local MAX_HOPS = 4
local BOOT = os.epoch and os.epoch("utc") or 0
-- Other programs on this computer (net.lua, install) send with their own boot
-- stamp, which can be the same millisecond. A random start keeps our
-- (from, boot, seq) dedupe keys distinct from theirs.
local seq = math.random(100000, 999999) * 1000

M.PROTOCOL = PROTOCOL
M.DEFAULT_TIMEOUT = 3      -- seconds to wait for the manifest
M.FILE_TIMEOUT = 5         -- seconds to wait for each file
M.PROTECTED = { ["startup.lua"] = true, ["startup"] = true }  -- only installed when missing

-- ---------------------------------------------------------------- versions

-- Version from the first line of a text: "-- Version: x.y.z". nil if absent.
function M.versionOf(text)
    if type(text) ~= "string" then return nil end
    local first = text:match("^([^\n]*)") or ""
    return first:match("^%s*%-%-%s*[Vv]ersion:%s*(%d+%.%d+%.%d+)")
end

-- Version of a local file, or nil if missing / no header.
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

-- -1 if a < b, 0 if equal, 1 if a > b. Unparsable counts as 0.0.0.
function M.compare(a, b)
    local pa, pb = parts(a) or { 0, 0, 0 }, parts(b) or { 0, 0, 0 }
    for i = 1, 3 do
        if pa[i] < pb[i] then return -1 end
        if pa[i] > pb[i] then return 1 end
    end
    return 0
end

-- ---------------------------------------------------------------- network

local function openModems()
    local opened = {}
    if not peripheral or not rednet then return opened, false end
    local any = false
    local names = peripheral.getNames and peripheral.getNames() or {}
    for _, name in ipairs(names) do
        if peripheral.getType(name) == "modem" then
            if rednet.isOpen(name) then
                any = true
            else
                local ok = pcall(rednet.open, name)
                if ok and rednet.isOpen(name) then
                    any = true
                    opened[#opened + 1] = name
                end
            end
        end
    end
    return opened, any
end

local function closeModems(opened)
    for _, name in ipairs(opened) do pcall(rednet.close, name) end
end

local function envelope(kind, to, body)
    seq = seq + 1
    local msg = {}
    for k, v in pairs(body or {}) do msg[k] = v end
    msg.v = 1
    msg.kind = kind
    msg.from = os.getComputerID()
    msg.to = to
    msg.boot = BOOT
    msg.seq = seq
    msg.ts = os.epoch("utc")
    msg.hops = 0
    return msg
end

local function send(kind, to, body)
    -- Always broadcast: if the update server is only reachable through a relay,
    -- a direct send would never arrive. The `to` field does the addressing.
    pcall(rednet.broadcast, envelope(kind, to, body), PROTOCOL)
end

-- Wait for a TMINER message of `kind` addressed to us, accepted by `match`.
-- Anything else (other traffic, garbage) is ignored until the deadline.
local function await(kind, timeout, match)
    local me = os.getComputerID()
    local deadline = os.clock() + timeout
    while true do
        local left = deadline - os.clock()
        if left <= 0 then return nil end
        local ok, id, msg = pcall(rednet.receive, PROTOCOL, left)
        if not ok or id == nil then return nil end
        if type(msg) == "table" and msg.v == 1 and msg.kind == kind
            and msg.to == me and type(msg.from) == "number"
            and (type(msg.hops) ~= "number" or msg.hops <= MAX_HOPS)
            and (match == nil or match(msg)) then
            return msg
        end
    end
end

-- ---------------------------------------------------------------- files

local function readAll(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

local function writeAll(path, text)
    local ok, err = pcall(function()
        local f = fs.open(path, "w")
        if not f then error("cannot open " .. path, 0) end
        local wok, werr = pcall(f.write, text)
        f.close()
        if not wok then error(werr, 0) end
    end)
    return ok, err
end

-- Check a Lua chunk compiles. Returns ok, err.
function M.validate(name, text)
    if type(text) ~= "string" or #text == 0 then return false, "empty" end
    local fn, err = load(text, "=" .. name, "t", {})
    if not fn then return false, tostring(err) end
    return true
end

local function stage(name, content)
    local tmp = name .. ".new"
    if fs.exists(tmp) then fs.delete(tmp) end
    local ok, err = writeAll(tmp, content)
    if not ok then
        if fs.exists(tmp) then fs.delete(tmp) end
        return false, "write failed: " .. tostring(err)
    end
    -- Validate what actually landed on disk, not just what we received.
    local back = readAll(tmp)
    if back ~= content then
        fs.delete(tmp)
        return false, "disk content mismatch (out of space?)"
    end
    local vok, verr = M.validate(name, back)
    if not vok then
        fs.delete(tmp)
        return false, "load() failed: " .. tostring(verr)
    end
    return true
end

local function swap(name)
    local tmp, bak = name .. ".new", name .. ".bak"
    local ok, err = pcall(function()
        if fs.exists(name) then
            if fs.exists(bak) then fs.delete(bak) end
            fs.copy(name, bak)
            fs.delete(name)
        end
        fs.move(tmp, name)
    end)
    if not ok then
        -- Put the old file back if the new one didn't make it.
        if not fs.exists(name) and fs.exists(bak) then pcall(fs.copy, bak, name) end
        if fs.exists(tmp) then pcall(fs.delete, tmp) end
        return false, tostring(err)
    end
    return true
end

-- ---------------------------------------------------------------- main

local function safeName(n)
    return type(n) == "string" and #n > 0 and #n <= 64
        and not n:find("[/\\:]") and not n:find("%.%.")
end

-- Ask for the manifest and work out what to fetch.
-- Returns list of {name, have, want, missing}, serverId  |  nil, reason
function M.check(opts)
    opts = opts or {}
    if not rednet then return nil, "no rednet" end
    local opened, any = openModems()
    if not any then return nil, "no modem" end
    send("update_check", "server", { role = opts.role or "miner" })
    local man = await("update_manifest", opts.timeout or M.DEFAULT_TIMEOUT, function(m)
        return type(m.files) == "table"
    end)
    closeModems(opened)
    if not man then return nil, "no update server" end

    local todo, seen = {}, {}
    local only = opts.files
    for _, e in ipairs(man.files) do
        if type(e) == "table" and safeName(e.name) and parts(e.version) and not seen[e.name] then
            seen[e.name] = true
            local wanted = only == nil
            if only then
                for _, n in ipairs(only) do if n == e.name then wanted = true end end
            end
            if wanted then
                local exists = fs.exists(e.name)
                local have = M.fileVersion(e.name)
                local need
                if M.PROTECTED[e.name] then
                    -- Only installed when missing, or replacing the installer's minimal fallback.
                    local cur = exists and readAll(e.name) or ""
                    need = (not exists) or (cur:find("Written by install", 1, true) ~= nil)
                else
                    need = (not exists) or M.compare(e.version, have) > 0
                end
                if need then
                    todo[#todo + 1] = { name = e.name, have = have, want = e.version, missing = not exists }
                end
            end
        end
    end
    table.sort(todo, function(a, b) return a.name < b.name end)
    return todo, man.from
end

-- Fetch, validate and install. Returns updated(bool), info table:
--   info.reason   why nothing happened ("no update server", "load() failed: ...")
--   info.files    names installed
--   info.pending  list from check() (what is out of date)
-- opts: timeout, fileTimeout, role, check (only report), files (restrict to names), log (fn)
local runInner

function M.run(opts)
    opts = opts or {}
    local opened = {}
    if peripheral and rednet then opened = openModems() end
    local ok, updated, info = pcall(runInner, opts)
    closeModems(opened)
    if not ok then
        return false, { files = {}, reason = "updater error: " .. tostring(updated) }
    end
    return updated, info
end

runInner = function(opts)
    local log = opts.log or function() end
    local info = { files = {} }

    local okc, todo, server = pcall(M.check, {
        timeout = opts.timeout, role = opts.role, files = opts.files,
    })
    if not okc then
        info.reason = "check failed: " .. tostring(todo)
        return false, info
    end
    if not todo then
        info.reason = server
        log(server)
        return false, info
    end
    info.pending = todo
    info.server = server
    if #todo == 0 then
        info.reason = "up to date"
        log("up to date")
        return false, info
    end
    for _, t in ipairs(todo) do
        log(("%s %s -> %s"):format(t.name, t.have or (t.missing and "missing" or "?"), t.want))
    end
    if opts.check then
        info.reason = "check only"
        return false, info
    end

    -- Download and stage every file first; only swap if all of them are good.
    local staged, failure = {}, nil
    for _, t in ipairs(todo) do
        local got
        for _ = 1, 2 do
            send("file_get", server, { name = t.name })
            got = await("file", opts.fileTimeout or M.FILE_TIMEOUT, function(m)
                return m.from == server and m.name == t.name
            end)
            if got then break end
        end
        if not got then
            failure = t.name .. ": no reply"
        elseif type(got.content) ~= "string" then
            failure = t.name .. ": " .. tostring(got.err or "no content")
        elseif M.compare(M.versionOf(got.content), t.want) < 0 then
            failure = t.name .. ": server sent older version than advertised"
        else
            local ok, err = stage(t.name, got.content)
            if ok then staged[#staged + 1] = t.name else failure = t.name .. ": " .. err end
        end
        if failure then break end
    end

    if failure then
        for _, name in ipairs(staged) do
            if fs.exists(name .. ".new") then fs.delete(name .. ".new") end
        end
        info.reason = failure
        log("update aborted, nothing changed: " .. failure)
        return false, info
    end

    for _, name in ipairs(staged) do
        local ok, err = swap(name)
        if ok then
            info.files[#info.files + 1] = name
            -- Make the new code take effect for any later require() in this run.
            if package and package.loaded then package.loaded[(name:gsub("%.lua$", ""))] = nil end
        else
            info.reason = name .. ": swap failed: " .. err
            log(info.reason)
        end
    end
    if #info.files > 0 then log("installed " .. #info.files .. " file(s)") end
    return #info.files > 0, info
end

-- ---------------------------------------------------------------- CLI

local first = ...
if first == nil or (type(first) == "string" and first:sub(1, 1) == "-") then
    local args = { ... }
    local checkOnly = false
    for _, a in ipairs(args) do
        if a == "--check" then checkOnly = true
        elseif a == "--help" or a == "-h" then
            print("Usage: updater [--check]")
            return M
        end
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
