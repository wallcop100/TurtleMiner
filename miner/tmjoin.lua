-- Version: 1.0.0
-- TurtleMiner mining network: create / join (docs/MESH_UPDATE_PLAN.md section 1). Used by
-- install (turtles), setup.lua (computers, pockets, relays) and the server UI.
--   * create: 4 random words from tmwords (about 40 bits) + optional network name; the key is
--     derived from both (tmcrypto.deriveKey, slowed down on purpose)
--   * join by typing the 4 words (any case or spacing; typos get "did you mean")
--   * join from a floppy disk (a drive next to the device) holding the network file
--   * join by approval: broadcast a join request, a server UI presses Approve (the key then
--     goes over the air: only safe if nobody else is listening at that moment)
-- Randomness: CC has no secure random source. The words come from SHA-256 over everything
-- available (epoch clocks, os.clock, computer id, table addresses, math.random); fine against
-- other players guessing, not against someone who can read your world save.
-- Usage: local J = require("tmjoin")

local J = {}

local function loadMod(name)
    if require then
        local ok, m = pcall(require, name)
        if ok and type(m) == "table" then return m end
    end
    for _, p in ipairs({ name .. ".lua", "/" .. name .. ".lua" }) do
        if fs and fs.exists(p) then
            local fn = loadfile(p, nil, _ENV)
            if fn then
                local ok, m = pcall(fn)
                if ok and type(m) == "table" then return m end
            end
        end
    end
    error(name .. ".lua is missing", 0)
end

local C = loadMod("tmcrypto")
local Wd = loadMod("tmwords")
J.C, J.Wd = C, Wd

J.DISK_FILE = "tm_network"
J.APPROVE_S = 120          -- how long a join request waits for Approve
J.REQ_EVERY = 5            -- seconds between join_req broadcasts

function J.load() return C.loadNetwork() end
function J.save(n) return C.saveNetwork(n) end
function J.phrase(n) return table.concat(n and n.words or {}, " ") end
function J.describe(n)
    if not n then return "no network" end
    return "network '" .. tostring(n.name) .. "'" .. ((n.words and #n.words > 0) and (": " .. J.phrase(n)) or "")
end

local function kdfYield()
    if os and os.queueEvent and os.pullEvent then
        os.queueEvent("tm_kdf")
        os.pullEvent("tm_kdf")
    end
end

local function entropy()
    local parts = {}
    local function add(v) parts[#parts + 1] = tostring(v) end
    if os.epoch then add(os.epoch("utc")); pcall(function() add(os.epoch("ingame")) end) end
    add(os.clock()); add(os.getComputerID and os.getComputerID())
    pcall(function() add(os.time()); add(os.day()) end)
    add(tostring({})); add(tostring(J)); add(tostring(function() end))
    for _ = 1, 8 do add(math.random(0, 1073741823)) end
    return C.sha256(table.concat(parts, "|"))
end

function J.randomWords(n)
    local d = entropy()
    local out = {}
    for i = 1, n or 4 do
        local hi, lo = d:byte(2 * i - 1, 2 * i)
        out[i] = Wd.LIST[(hi * 256 + lo) % #Wd.LIST + 1]
    end
    return out
end

function J.make(name, words, yield)
    name = C.normName(name)
    return { name = name, words = words, key = C.deriveKey(name, words, yield or kdfYield) }
end

function J.create(name) return J.make(name, J.randomWords(4)) end

-- "w1 w2 w3 w4" or "name: w1 w2 w3 w4". Returns net | nil, err.
function J.fromText(text, name)
    text = tostring(text or "")
    local pre, rest = text:match("^%s*([%w_%-]+)%s*:(.*)$")
    if pre then name, text = pre, rest end
    local ws, err = Wd.parse(text)
    if not ws then return nil, err end
    return J.make(name, ws)
end

-- Disk drives ----------------------------------------------------------------
function J.findDisk()
    if not peripheral then return nil end
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "drive" then
            local okP, present = pcall(peripheral.call, n, "isDiskPresent")
            local okM, mount = pcall(peripheral.call, n, "getMountPath")
            if okP and present and okM and type(mount) == "string" then return mount, n end
        end
    end
    return nil
end

function J.diskFile()
    local mount = J.findDisk()
    return mount and fs.combine(mount, J.DISK_FILE) or nil
end

function J.toDisk(n)
    n = n or J.load()
    if not n then return false, "this device has no network" end
    local mount, drive = J.findDisk()
    if not mount then return false, "no disk in a drive next to this device" end
    local ok, err = C.saveNetwork(n, fs.combine(mount, J.DISK_FILE))
    if not ok then return false, err end
    pcall(peripheral.call, drive, "setDiskLabel", "TM network " .. n.name)
    return true
end

function J.fromDisk()
    local p = J.diskFile()
    if not p then return nil end
    return C.loadNetwork(p), p
end

function J.wipeDisk()
    local p = J.diskFile()
    if p and fs.exists(p) then fs.delete(p); return true end
    return false
end

-- Approve on a monitor ----------------------------------------------------------
local function openModems()
    local any = false
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "modem" then
            pcall(rednet.open, n)
            if rednet.isOpen(n) then any = true end
        end
    end
    return any
end

-- Broadcasts a join request every 5 s until a server UI approves it (or timeout).
-- Returns net | nil, err.
function J.requestApproval(opts)
    opts = opts or {}
    local say = opts.print or print
    if not (rednet and peripheral) or not openModems() then return nil, "no modem" end
    local me = os.getComputerID()
    local nonce = C.toHex(entropy()):sub(1, 16)
    local label = os.getComputerLabel() or ((turtle and "turtle" or (pocket and "pocket" or "computer")) .. " " .. me)
    local boot, seq = os.epoch("utc"), math.random(1, 99999)
    local timeout = opts.timeout or J.APPROVE_S
    local deadline = os.clock() + timeout
    say("Asking to join. On the monitor: open NET, approve #" .. me .. " '" .. label .. "' (" .. timeout .. " s).")
    while os.clock() < deadline do
        seq = seq + 1
        pcall(rednet.broadcast, { v = 1, kind = "join_req", from = me, to = "server", boot = boot, seq = seq,
            ts = os.epoch("utc"), hops = 0, label = label, nonce = nonce,
            dev = turtle and "turtle" or (pocket and "pocket" or "computer") }, "TMINER")
        local wait = os.clock() + J.REQ_EVERY
        while os.clock() < wait and os.clock() < deadline do
            local id, m = rednet.receive("TMINER", math.max(0.1, math.min(wait, deadline) - os.clock()))
            if id and type(m) == "table" and m.kind == "join_ok" and m.to == me and m.nonce == nonce
                and C.validNetwork(m.network) then
                local n = { name = C.normName(m.network.name), words = m.network.words, key = m.network.key }
                local s = C.signer(n)
                if s and s.check(m) then
                    say("Approved by #" .. tostring(m.from))
                    return n
                end
            end
        end
    end
    return nil, "not approved within " .. timeout .. " s"
end

-- Interactive / flag-driven setup ------------------------------------------------
-- opts: join (text), create (name or true), name, disk (bool: take from disk), approve (bool),
--   change (replace an existing network), auto (no questions), wipe (wipe the disk after a
--   disk join, auto mode), print, read.
-- Returns net, how | nil, err. Saves .tm_network.
function J.ensure(opts)
    opts = opts or {}
    local say = opts.print or print
    local ask = opts.read or read
    local have = J.load()
    if have and not opts.change then return have, "existing" end
    local n, err, how
    local function question(q, default)
        if opts.auto then return default end
        write(q .. (default and (" [" .. default .. "]") or "") .. ": ")
        local a = ask()
        if a == nil or a:match("^%s*$") then return default end
        return (a:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    if opts.join then
        n, err = J.fromText(opts.join, opts.name)
        how = "joined"
    elseif opts.create then
        n = J.create(opts.create ~= true and opts.create or opts.name)
        how = "created"
    elseif opts.approve then
        n, err = J.requestApproval({ print = say, timeout = opts.timeout })
        how = "approved"
    else
        local dn, dpath = J.fromDisk()
        if dn and (opts.disk or opts.auto
            or (question("Use " .. J.describe({ name = dn.name }) .. " from the disk? (Y/n)", "y")):lower():sub(1, 1) == "y") then
            n, how = dn, "disk"
            local wipe = opts.wipe
            if not opts.auto then
                wipe = question("Wipe the network from the disk now? (y/N)", "n"):lower():sub(1, 1) == "y"
            end
            if wipe then fs.delete(dpath); say("disk wiped") end
        elseif opts.disk then
            return nil, "no network file on a disk next to this device"
        elseif opts.auto then
            return nil, "no mining network: use --join \"<4 words>\" or --create <name>"
        else
            say("Mining network: every device must join the same one.")
            say(" 1  create a new network")
            say(" 2  join: type its 4 words")
            say(" 3  join: approve on the monitor")
            local c = question("Choice", have and "2" or "1")
            if c == "1" then
                n = J.create(question("Network name", "mine"))
                how = "created"
            elseif c == "3" then
                n, err = J.requestApproval({ print = say })
                how = "approved"
            else
                local name = question("Network name", "mine")
                while true do
                    local text = question("The 4 words", nil)
                    if text == nil then return nil, "cancelled" end
                    n, err = J.fromText(text, name)
                    if n then break end
                    say("  " .. tostring(err))
                end
                how = "joined"
            end
        end
    end
    if not n then return nil, err end
    local ok, serr = J.save(n)
    if not ok then return nil, serr end
    if how == "created" then
        say("New " .. J.describe(n))
        say("Write these 4 words down: every other device joins with them.")
        if not opts.auto then question("Press Enter when you have written them down", nil) end
    else
        say("Joined network '" .. n.name .. "'")
    end
    return n, how
end

-- Parse CLI flags shared by install and setup into J.ensure options. Returns opts, rest.
function J.parseArgs(args)
    local o, rest = {}, {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--join" then
            -- `--join "a b c d"` or `--join a b c d`
            local ws = {}
            while args[i + 1] and args[i + 1]:sub(1, 2) ~= "--" do ws[#ws + 1] = args[i + 1]; i = i + 1 end
            o.join = table.concat(ws, " ")
        elseif a == "--create" then
            local nx = args[i + 1]
            if nx and nx:sub(1, 2) ~= "--" then o.create = nx; i = i + 1 else o.create = true end
        elseif a == "--name" then o.name = args[i + 1]; i = i + 1
        elseif a == "--disk" then o.disk = true
        elseif a == "--wipe-disk" then o.wipe = true
        elseif a == "--approve" then o.approve = true
        elseif a == "--to-disk" then o.toDisk = true
        else rest[#rest + 1] = a end
        i = i + 1
    end
    return o, rest
end

return J
