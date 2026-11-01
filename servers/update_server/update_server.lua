-- Version: 1.3.0
-- TurtleMiner update server. Serves the files in FILES_DIR to turtles over
-- rednet protocol "TMINER" (update_check -> update_manifest, file_get -> file).
-- Versions come from each file's first line: "-- Version: x.y.z".
-- If FILES_DIR/<role>/ exists (e.g. /files/miner/), that role is served from
-- there; otherwise every role gets FILES_DIR itself. It relays nothing.
--
-- Usage: update_server [dir]     (default /files/, or settings tminer.update_dir)

local PROTOCOL = "TMINER"
local MAX_HOPS = 4

local args = { ... }
-- tminer_server (installed next to this by setup / GitHub pull) serves updates itself, with
-- one answer per cluster. An old startup that still runs this next to it: stay out of the way.
if fs.exists("tminer_server.lua") and fs.exists("tm_update.lua") then
    print("update_server: tminer_server serves updates on this PC; nothing to do.")
    while true do sleep(3600) end
end
if settings then pcall(settings.load) end
local FILES_DIR = args[1] or (settings and settings.get("tminer.update_dir")) or "/files/"
if FILES_DIR:sub(-1) ~= "/" then FILES_DIR = FILES_DIR .. "/" end

local ME = os.getComputerID()
local BOOT = os.epoch("utc")
local seq = 0
local seen, seenOrder = {}, {}
local served, checks = 0, 0

local function log(s)
    print(os.date("%H:%M:%S") .. " " .. s)
end

-- ------------------------------------------------------------- files

local function versionOf(line)
    if type(line) ~= "string" then return nil end
    return line:match("^%s*%-%-%s*[Vv]ersion:%s*(%d+%.%d+%.%d+)")
end

local function safeName(n)
    return type(n) == "string" and #n > 0 and #n <= 64
        and not n:find("[/\\:]") and not n:find("%.%.")
end

local function roleDir(role)
    if safeName(role) and fs.isDir(FILES_DIR .. role) then
        return FILES_DIR .. role .. "/"
    end
    return FILES_DIR
end

-- Built fresh on every request, so dropping in a new file needs no restart.
local function manifest(role)
    local dir = roleDir(role)
    local list = {}
    if not fs.isDir(dir) then return list, dir end
    for _, name in ipairs(fs.list(dir)) do
        local path = dir .. name
        if not fs.isDir(path) and safeName(name) and not name:match("%.bak$") and not name:match("%.new$") then
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

local function readFile(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

-- ------------------------------------------------------------- network

local function openModems()
    local n = 0
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then pcall(rednet.open, name) end
            if rednet.isOpen(name) then n = n + 1 end
        end
    end
    return n
end

local function envelope(kind, to, body)
    seq = seq + 1
    body.v, body.kind, body.from, body.to = 1, kind, ME, to
    body.boot, body.seq, body.ts, body.hops = BOOT, seq, os.epoch("utc"), 0
    body.hop, body.ohop = 0, 0      -- a server: distance 0 (docs/COMMS.md)
    return body
end

-- Reply to whoever handed us the message (the turtle, or a relay that will
-- forward it because `to` is the turtle).
local function reply(viaId, kind, to, body)
    pcall(rednet.send, viaId, envelope(kind, to, body), PROTOCOL)
end

local function isDuplicate(msg)
    local key = tostring(msg.from) .. ":" .. tostring(msg.boot) .. ":" .. tostring(msg.seq)
    if seen[key] then return true end
    seen[key] = true
    seenOrder[#seenOrder + 1] = key
    if #seenOrder > 256 then
        seen[table.remove(seenOrder, 1)] = nil
    end
    return false
end

local function forUs(to)
    return to == "server" or to == ME
end

local function handle(viaId, msg)
    if type(msg) ~= "table" or msg.v ~= 1 or type(msg.kind) ~= "string" then return end
    if type(msg.from) ~= "number" then return end
    if type(msg.hops) == "number" and msg.hops > MAX_HOPS then return end
    if msg.kind ~= "update_check" and msg.kind ~= "file_get" then return end
    if not forUs(msg.to) then return end
    if isDuplicate(msg) then return end

    local role = type(msg.role) == "string" and msg.role or "miner"
    if msg.kind == "update_check" then
        local files = manifest(role)
        checks = checks + 1
        reply(viaId, "update_manifest", msg.from, { files = files })
        log(("check from #%d (%s): %d file(s)"):format(msg.from, role, #files))
    else
        local name = msg.name
        local content, version, err
        if not safeName(name) then
            err = "bad name"
        else
            local path = roleDir(role) .. name
            if fs.exists(path) and not fs.isDir(path) then
                content = readFile(path)
                version = versionOf(content and content:match("^([^\n]*)")) or "0.0.0"
                if not content then err = "read failed" end
            else
                err = "not found"
            end
        end
        reply(viaId, "file", msg.from, { name = name, version = version, content = content, err = err })
        if content then
            served = served + 1
            log(("sent %s v%s to #%d (%d bytes)"):format(name, version, msg.from, #content))
        else
            log(("file_get %s from #%d: %s"):format(tostring(name), msg.from, err))
        end
    end
end

-- ------------------------------------------------------------- main

if openModems() == 0 then
    error("No modem attached. Attach a wireless or ender modem.", 0)
end
if not fs.isDir(FILES_DIR) then fs.makeDir(FILES_DIR) end

-- GitHub auto-pull (github_pull.lua next to this program; optional).
package.path = "/?.lua;/?;" .. package.path
local okp, puller = pcall(require, "github_pull")
if not okp then puller = nil end
local function doPull(atBoot)
    if not puller then return end
    print("Checking GitHub for newer files...")
    local ok, changed, serverChanged, err = pcall(puller.pull, FILES_DIR, log)
    if not ok then log("pull error: " .. tostring(changed)) return end
    if err then log("pull: " .. err) end
    log(("pull: %d file(s) updated"):format(#changed))
    if serverChanged then
        -- New server programs: restart once to run them (guard against loops).
        local guard = ".pull_reboot"
        local last = tonumber((function()
            if not fs.exists(guard) then return nil end
            local f = fs.open(guard, "r"); local t = f.readAll(); f.close(); return t
        end)())
        if not last or os.epoch("utc") - last > 120000 then
            local f = fs.open(guard, "w"); f.write(tostring(os.epoch("utc"))); f.close()
            log("server programs updated, rebooting")
            sleep(1)
            os.reboot()
        end
    end
end
doPull(true)

term.clear()
term.setCursorPos(1, 1)
print("TurtleMiner update server #" .. ME)
print("Serving " .. FILES_DIR .. " on protocol " .. PROTOCOL)
local list, dir = manifest("miner")
print(("miner role: %d file(s) from %s"):format(#list, dir))
for _, e in ipairs(list) do print("  " .. e.name .. " " .. e.version) end
if #list == 0 then printError("No files! Copy the miner/*.lua files into " .. FILES_DIR) end
print("Press Q to quit.")

local function listen()
    while true do
        local id, msg = rednet.receive(PROTOCOL)
        local ok, err = pcall(handle, id, msg)
        if not ok then log("error: " .. tostring(err)) end
    end
end

local function keysLoop()
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.q then return end
    end
end

local function pullLoop()
    local m = puller and puller.interval() or 0
    if m <= 0 then while true do sleep(3600) end end
    while true do
        sleep(m * 60)
        doPull(false)
    end
end

parallel.waitForAny(listen, keysLoop, pullLoop)
-- Let the Q key event go before the shell sees it.
sleep(0)
print(("Stopped. %d check(s), %d file(s) sent."):format(checks, served))
return true
