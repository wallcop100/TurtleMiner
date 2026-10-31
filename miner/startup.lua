-- Version: 1.0.0
-- TurtleMiner turtle startup. Checks for updates only when the turtle is at
-- home (or has no state yet), reboots at most once after an update, then
-- starts the miner. Nothing here ever waits for input.

local GUARD = ".tm_updated"   -- exists for exactly one boot after an update

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
local function atHome()
    local text = readFile(".tm_state") or readFile(".tm_state.tmp")
    if not text then return true end
    local st = textutils.unserialize(text)
    if type(st) ~= "table" then return false end
    local pos = st.pos
    -- The journal records moves since the snapshot; the last line wins.
    local j = readFile(".tm_journal")
    if j then
        local last
        for line in j:gmatch("[^\n]+") do last = line end
        if last then
            local tag = last:match("^(%a)")
            if tag == "I" then return false end
            if tag == "D" then
                local x, y, z = last:match("^D%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")
                if x then pos = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
            end
        end
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
        return require("updater").run({ log = function(s) print("[update] " .. s) end })
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

shell.run("miner")
