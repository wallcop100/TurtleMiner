-- Version: 1.2.0
-- TurtleMiner installer. The only program that asks questions.
--
--   install              check hardware, fetch missing files, ask 4-5 questions
--                        (plus one if old miner state is found)
--   install --default    same, but no questions (keeps current values / defaults)
--
-- A fresh turtle only needs this file: missing miner files are fetched from the
-- update server (rednet protocol "TMINER").

-- Under `wget run`, require() would search the wget program's folder, not /.
package.path = "/?.lua;/?;" .. package.path

local args = { ... }
local USE_DEFAULTS = false
for _, a in ipairs(args) do
    if a == "--default" or a == "-d" then USE_DEFAULTS = true
    elseif a == "--help" or a == "-h" then
        print("Usage: install [--default]")
        return
    end
end

local REQUIRED = {
    "config.lua", "state.lua", "nav.lua", "inv.lua", "mine.lua",
    "net.lua", "miner.lua", "updater.lua", "startup.lua",
}
-- Files from the old miner. They are dead code now and an old startup could run them.
local OLD_FILES = {
    "miner_core.lua", "miner_mining.lua", "miner_movement.lua", "miner_inventory.lua",
    "miner_persistence.lua", "miner_status.lua", "miner_config.lua", "turtle_status.lua",
    "turtle_updater.lua", "turtle_miner_network.lua",
}
-- Used only if config.lua can't be loaded.
local FALLBACK = { TARGET_Y = -58, FOCUS = "all", MAX_CORRIDORS = 8 }

local function say(colour, text)
    if term.isColour and term.isColour() then term.setTextColour(colour) end
    print(text)
    if term.isColour and term.isColour() then term.setTextColour(colours.white) end
end
local function ok(t) say(colours.lime, "  ok   " .. t) end
local function warn(t) say(colours.yellow, "  warn " .. t) end
local function bad(t) say(colours.red, "  FAIL " .. t) end

local function ask(question, default)
    if USE_DEFAULTS then return tostring(default) end
    write(question .. " [" .. tostring(default) .. "]: ")
    local answer = read()
    if answer == nil or answer:match("^%s*$") then return tostring(default) end
    return (answer:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function yes(question, default)
    if USE_DEFAULTS then return default end
    local a = ask(question .. (default and " (Y/n)" or " (y/N)"), default and "y" or "n")
    return a:lower():sub(1, 1) == "y"
end

local function missingFiles()
    local list = {}
    for _, name in ipairs(REQUIRED) do
        if not fs.exists(name) then list[#list + 1] = name end
    end
    return list
end

-- ------------------------------------------------------------ bootstrap fetch
-- Minimal client for the update sub-protocol, only used to get updater.lua
-- itself; everything else goes through the updater.

local function fetchUpdater()
    local opened = {}
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "modem" and not rednet.isOpen(n) then
            pcall(rednet.open, n)
            if rednet.isOpen(n) then opened[#opened + 1] = n end
        end
    end
    local boot, seq, me = os.epoch("utc"), math.random(1, 99999), os.getComputerID()
    local function send(kind, to, body)
        seq = seq + 1
        body.v, body.kind, body.from, body.to = 1, kind, me, to
        body.boot, body.seq, body.ts, body.hops = boot, seq, os.epoch("utc"), 0
        rednet.broadcast(body, "TMINER")
    end
    local function await(kind, timeout, match)
        local deadline = os.clock() + timeout
        while os.clock() < deadline do
            local id, m = rednet.receive("TMINER", deadline - os.clock())
            if not id then return nil end
            if type(m) == "table" and m.v == 1 and m.kind == kind and m.to == me
                and type(m.from) == "number" and match(m) then
                return m
            end
        end
    end
    local result, reason = false, "no update server"
    send("update_check", "server", { role = "miner" })
    local man = await("update_manifest", 3, function(m) return type(m.files) == "table" end)
    if man then
        reason = "server has no updater.lua"
        for _, e in ipairs(man.files) do
            if type(e) == "table" and e.name == "updater.lua" then
                send("file_get", man.from, { name = "updater.lua" })
                local f = await("file", 5, function(m) return m.from == man.from and m.name == "updater.lua" end)
                if f and type(f.content) == "string" and load(f.content, "=updater.lua", "t", {}) then
                    local h = fs.open("updater.lua", "w")
                    h.write(f.content)
                    h.close()
                    result, reason = true, nil
                else
                    reason = "updater.lua download failed"
                end
            end
        end
    end
    for _, n in ipairs(opened) do pcall(rednet.close, n) end
    return result, reason
end

-- One TMINER message to the servers (fire and forget). Returns true if a modem was open.
local function sendToServers(kind, body)
    local opened = {}
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "modem" and not rednet.isOpen(n) then
            pcall(rednet.open, n)
            if rednet.isOpen(n) then opened[#opened + 1] = n end
        end
    end
    local any = rednet.isOpen()
    if any then
        local t = os.epoch("utc")
        body.v, body.kind, body.from, body.to = 1, kind, os.getComputerID(), "server"
        body.boot, body.seq, body.ts, body.hops = t, math.random(1, 99999), t, 0
        pcall(rednet.broadcast, body, "TMINER")
    end
    for _, n in ipairs(opened) do pcall(rednet.close, n) end
    return any
end

-- ------------------------------------------------------------ checks

term.clear()
term.setCursorPos(1, 1)
print("TurtleMiner installer" .. (USE_DEFAULTS and " (defaults)" or ""))
print("")

if not turtle then
    bad("this is not a turtle. On a monitor or pocket computer, run central_monitor instead.")
    return
end

print("Hardware:")
local modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
    or peripheral.find("modem")
if modem then
    ok("modem found")
else
    warn("no modem: works offline, but no monitor, no updates, no fetching files")
end

local function toolName(get)
    if not get then return nil end
    local okc, item = pcall(get)
    if okc and type(item) == "table" then return item.name end
    return false
end
if turtle.getEquippedLeft or turtle.getEquippedRight then
    local l, r = toolName(turtle.getEquippedLeft), toolName(turtle.getEquippedRight)
    if (l and l:find("pickaxe")) or (r and r:find("pickaxe")) then
        ok("pickaxe equipped")
    else
        bad("no pickaxe equipped (left: " .. tostring(l or "empty") .. ", right: " .. tostring(r or "empty") .. ")")
        warn("equip a diamond pickaxe: put it in the selected slot and run 'equip right' (lua: turtle.equipRight())")
    end
else
    warn("can't check tools on this CC version: make sure a pickaxe is equipped")
end

local fuel = turtle.getFuelLevel()
if fuel == "unlimited" then
    ok("fuel: unlimited")
elseif fuel < 500 then
    warn("fuel is " .. fuel .. ". Put coal in the turtle (it refuels from inventory) or a fuel chest at home.")
else
    ok("fuel: " .. fuel)
end

-- ------------------------------------------------------------ files

print("")
print("Files:")
local missing = missingFiles()
if #missing > 0 then
    print("  missing: " .. table.concat(missing, ", "))
    if modem then
        if not fs.exists("updater.lua") then
            print("  fetching updater.lua from the update server...")
            local got, why = fetchUpdater()
            if not got then warn(why) end
        end
    else
        warn("no modem, can't fetch them")
    end
end
if modem and fs.exists("updater.lua") then
    print("  checking the update server...")
    local okr, updated, info = pcall(function() return require("updater").run({ log = function(s) print("    " .. s) end }) end)
    if not okr then
        warn("updater error: " .. tostring(updated))
    elseif not updated and info and info.reason and info.reason ~= "up to date" then
        warn(info.reason)
    end
end
missing = missingFiles()
local onlyStartup = #missing == 1 and missing[1] == "startup.lua"
if #missing == 0 or onlyStartup then
    ok("miner files present")
else
    bad("still missing: " .. table.concat(missing, ", "))
    print("  Start the update server (see README), or copy the files from disk, then run install again.")
end

local removed = {}
for _, name in ipairs(OLD_FILES) do
    if fs.exists(name) then
        fs.delete(name)
        removed[#removed + 1] = name
    end
end
if #removed > 0 then ok("removed old files: " .. table.concat(removed, ", ")) end

-- ------------------------------------------------------------ settings

print("")
print("Settings:")
pcall(settings.load)
local config
do
    local okc, c = pcall(require, "config")
    if okc and type(c) == "table" and c.DEFAULTS then config = c end
end
local function current(key)
    local v = settings.get("tminer." .. key)
    if v ~= nil then return v end
    return config and config.DEFAULTS[key] or FALLBACK[key]
end
local function store(key, value)
    if config then return config.set(key, value) end
    settings.set("tminer." .. key, value)
    settings.save()
    return true
end

local label = ask("Turtle name", os.getComputerLabel() or ("Miner-" .. os.getComputerID()))
os.setComputerLabel(label)

local function askNumber(key, question)
    while true do
        local v = tonumber(ask(question, current(key)))
        if v then
            local good, err = store(key, math.floor(v))
            if good then return math.floor(v) end
            bad(err)
        else
            bad("enter a number")
        end
        if USE_DEFAULTS then return current(key) end
    end
end

-- Without GPS the miner works in a relative frame and needs the real Y of
-- the home spot so TARGET_Y means the same thing as with GPS.
local gx, gy = nil, nil
if gps and modem then
    local side = peripheral.getName(modem)
    local wasOpen = rednet.isOpen(side)
    if not wasOpen then pcall(rednet.open, side) end
    gx, gy = gps.locate(2)
    if not wasOpen then pcall(rednet.close, side) end
end
if gy then
    ok("GPS found (Y " .. math.floor(gy + 0.5) .. "), HOME_Y not needed")
else
    warn("no GPS: the miner needs this turtle's Y level (F3 screen, the turtle's block)")
    askNumber("HOME_Y", "Home Y level")
end

local targetY = askNumber("TARGET_Y", "Mining level Y (-58 for diamonds in 1.18+)")
local focus
while true do
    focus = ask("Ore focus (all, diamond, iron, ancient_debris, ...)", current("FOCUS")):lower()
    local good, err = store("FOCUS", focus)
    if good then break end
    bad(err)
    if USE_DEFAULTS then focus = current("FOCUS") break end
end
local maxCorr = askNumber("MAX_CORRIDORS", "Corridors to mine before stopping")

ok(("label %s, Y %d, focus %s, %d corridors"):format(label, targetY, focus, maxCorr))

-- ------------------------------------------------------------ home record

-- The miner keeps its position in .tm_state/.tm_journal and the servers keep a
-- backup of its home. Setting up at a new spot must forget both, or the miner
-- would think it is still at (or must walk back to) the old home.
local STATE_FILES = { ".tm_state", ".tm_state.tmp", ".tm_journal", ".tm_journal.tmp" }
local hasState = false
for _, f in ipairs(STATE_FILES) do if fs.exists(f) then hasState = true end end
if hasState and yes("Old miner state found. Is this a NEW home spot (forget old position and job)?", false) then
    for _, f in ipairs(STATE_FILES) do if fs.exists(f) then fs.delete(f) end end
    hasState = false
    ok("old state deleted: this spot becomes home on the next start")
end
if not hasState then
    -- No local state: the next start sets home here. Drop the servers' old record so
    -- a later state loss can't send the turtle back to a previous home.
    if modem and sendToServers("home_clear", {}) then
        ok("asked the servers to forget this turtle's old home")
    end
else
    ok("keeping the saved position and job")
end

-- ------------------------------------------------------------ startup

local STARTUP_FALLBACK = '-- Version: 1.0.0\n-- Written by install (no startup.lua from the update server).\nshell.run("miner")\n'
if not fs.exists("startup.lua") and not fs.exists("startup") then
    local h = fs.open("startup.lua", "w")
    h.write(STARTUP_FALLBACK)
    h.close()
    warn("wrote a minimal startup.lua; the updater replaces it with the full one when the server has it")
else
    local name = fs.exists("startup.lua") and "startup.lua" or "startup"
    local h = fs.open(name, "r")
    local text = h.readAll()
    h.close()
    if text:find('shell.run("miner")', 1, true) then
        ok(name .. " starts the miner")
    elseif yes(name .. " does not start the miner. Replace it?", false) then
        fs.delete(name)
        local w = fs.open("startup.lua", "w")
        w.write(STARTUP_FALLBACK)
        w.close()
        ok("startup.lua replaced; run 'updater' to get the full one")
    else
        warn(name .. " left as is: the miner won't start on boot")
    end
end

-- ------------------------------------------------------------ done

print("")
print("Home spot: chest behind or beside the turtle (NOT below:")
print("the shaft goes straight down). Optional fuel chest anywhere adjacent.")
local hasDown, down = turtle.inspectDown()
if hasDown and type(down) == "table" and tostring(down.name):find("chest") then
    warn("chest below the turtle: move it behind or beside, or the miner will stop at the shaft")
end
print("Change settings later with: set tminer.<KEY> <value>")
if #missing == 0 or onlyStartup then
    if yes("Start mining now?", false) then
        shell.run("miner")
    else
        print("Reboot or run 'miner' to start.")
    end
end
