-- Version: 2.0.0
-- TurtleMiner turtle startup. Installs a fetched mesh update only when the turtle is at
-- home (or has no state yet), reboots at most once after an update, then starts the miner.
-- Nothing here waits for input (except the one-time network prompt, 60 s).
-- Update probation (tmguard.lua): an interrupted install is finished first; a crash of the
-- miner, or more than 2 extra reboots, right after an update puts the old files back.

local GUARD = ".tm_updated"   -- exists for exactly one boot after an update

local guard = nil
do
    local fn = fs.exists("tmguard.lua") and loadfile("tmguard.lua", nil, _ENV)
    local ok, g = pcall(fn or error)
    if ok and type(g) == "table" then guard = g end
end
if guard then
    local ok, err = pcall(guard.boot)
    if not ok then print("[update] guard: " .. tostring(err)) end
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

local function samePos(a, b)
    return type(a) == "table" and type(b) == "table"
        and tonumber(a.x) == tonumber(b.x) and tonumber(a.y) == tonumber(b.y)
        and tonumber(a.z) == tonumber(b.z) and tonumber(a.x) ~= nil
end

-- true when it is safe to update: no state at all, or the last known
-- position is home and no move was in flight.
--   R lines (refuels) say nothing about position: skipped.
--   D lines carry the position after a move: the last one wins.
--   S lines mark a snapshot (older ones are kept as history): their position,
--   unless D lines follow.
--   Last record an I line: a move may be half done, so not at home.
local function atHome()
    local text = readFile(".tm_state") or readFile(".tm_state.tmp")
    if not text then return true end
    local st = textutils.unserialize(text)
    if type(st) ~= "table" then return false end
    local pos = st.pos
    local j = readFile(".tm_journal")
    if j then
        local lastTag
        for line in j:gmatch("[^\n]+") do
            local tag = line:match("^(%a)")
            if tag == "D" or tag == "S" then
                local x, y, z = line:match("^%a%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")
                if x then pos = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
                elseif tag == "S" then pos = st.pos end
                lastTag = tag
            elseif tag == "I" then
                lastTag = tag
            end
        end
        if lastTag == "I" then return false end
    end
    return samePos(pos, st.home)
end

local function autoUpdate()
    if settings then pcall(settings.load) end
    if settings and settings.get("tminer.AUTO_UPDATE") == false then return false end
    if not fs.exists("updater.lua") and not fs.exists("updater") then return false end
    local okHome, home = pcall(atHome)
    if not okHome or not home then return false end
    local ok, updated = pcall(function()
        -- Only what the mesh already fetched (no network wait at boot).
        return require("updater").run({ stagedOnly = true, log = function(s) print("[update] " .. s) end })
    end)
    if not ok then
        print("[update] failed: " .. tostring(updated))
        return false
    end
    return updated == true
end

if fs.exists(GUARD) then
    -- We rebooted after an update last time: don't check again this boot.
    fs.delete(GUARD)
elseif autoUpdate() then
    local f = fs.open(GUARD, "w")
    if f then
        f.write(tostring(os.epoch("utc")))
        f.close()
        print("[update] rebooting into the new version")
        sleep(1)
        os.reboot()
    end
end

-- No mining network yet: offer to set one up (60 s, then the turtle mines offline).
do
    local okJ, J = pcall(require, "tmjoin")
    local hasModem = peripheral and peripheral.find and peripheral.find("modem") ~= nil
    if okJ and J.bootPrompt and hasModem then J.bootPrompt({ timeout = 60 }) end
end
if guard then guard.run("miner") else shell.run("miner") end
