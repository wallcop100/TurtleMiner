-- Version: 1.0.0
-- TurtleMiner inventory and fuel (WP-B).
-- Refuel with a reserve, trash dropping, home storage detection, unload, fuel restock.
-- Never prompts. Every turn it makes is undone before returning.

local inv = {}

local st, cfg, nav

local SIDES = { "front", "top", "bottom", "left", "right", "back" }

-- Fuel value per item (by name without namespace). Lava buckets are deliberately not handled.
local FUEL_VALUE = { coal = 80, charcoal = 80, coal_block = 800, blaze_rod = 120 }

local function baseName(name)
    return name:match(":(.+)$") or name
end

local function fuelValue(name)
    if type(name) ~= "string" then return nil end
    return FUEL_VALUE[baseName(name)]
end
inv.fuelValue = fuelValue

local function logRefuel(fuel)
    local ok, state = pcall(require, "state")
    if ok and type(state) == "table" and state.logRefuel then
        pcall(state.logRefuel, fuel)
    end
end

local function fuelLimit()
    if turtle.getFuelLimit then
        local l = turtle.getFuelLimit()
        if type(l) == "number" then return l end
    end
    return nil
end

local function fuelItemCount()
    local n = 0
    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and fuelValue(d.name) then n = n + d.count end
    end
    return n
end
inv.fuelItemCount = fuelItemCount

-- Turn to face a direction through nav (journalled); no-op if already facing it.
local function face(dir)
    if st.facing ~= dir then nav.face(dir) end
end

-- Facing that `side` refers to; sides are always measured relative to homeFacing.
local function sideFacing(side)
    local base = st.homeFacing or st.facing
    if side == "front" then return base end
    if side == "right" then return (base + 1) % 4 end
    if side == "back" then return (base + 2) % 4 end
    if side == "left" then return (base + 3) % 4 end
    return nil
end

-- Run fn(drop, suck) with the turtle facing `side`; restores the original facing afterwards.
local function atSide(side, fn)
    local orig = st.facing
    local drop, suck
    if side == "top" then
        drop, suck = turtle.dropUp, turtle.suckUp
    elseif side == "bottom" then
        drop, suck = turtle.dropDown, turtle.suckDown
    else
        drop, suck = turtle.drop, turtle.suck
        face(sideFacing(side))
    end
    local a, b = fn(drop, suck)
    face(orig)
    return a, b
end

function inv.init(state_, cfg_, nav_)
    st, cfg, nav = state_, cfg_, nav_
    inv.home = nil
end

function inv.slotsFree()
    local n = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then n = n + 1 end
    end
    return n
end

function inv.isFull()
    return inv.slotsFree() < 2
end

local function isTrash(name)
    if type(name) ~= "string" or type(cfg.TRASH) ~= "table" then return false end
    local base = baseName(name)
    for _, t in ipairs(cfg.TRASH) do
        if t == name or (not t:find(":", 1, true) and t == base) then return true end
    end
    return false
end

function inv.dropTrash()
    local freed = 0
    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and isTrash(d.name) then
            turtle.select(slot)
            turtle.dropDown()
            if turtle.getItemCount(slot) == 0 then freed = freed + 1 end
        end
    end
    turtle.select(1)
    return freed
end

-- Burn fuel items until fuel >= target, keeping cfg.FUEL_KEEP fuel items in reserve.
function inv.refuel(target)
    local fuel = turtle.getFuelLevel()
    if fuel == "unlimited" then return fuel end
    local limit = fuelLimit()
    if limit and target > limit then target = limit end
    if fuel >= target then return fuel end
    local spare = fuelItemCount() - (cfg.FUEL_KEEP or 0)
    local burned = false
    for slot = 1, 16 do
        if fuel >= target or spare <= 0 then break end
        local d = turtle.getItemDetail(slot)
        local v = d and fuelValue(d.name)
        if v then
            local n = math.ceil((target - fuel) / v)
            if n > d.count then n = d.count end
            if n > spare then n = spare end
            if limit then
                local room = math.floor((limit - fuel) / v)
                if n > room then n = room end
            end
            if n > 0 then
                turtle.select(slot)
                if turtle.refuel(n) then
                    spare = spare - n
                    burned = true
                    fuel = turtle.getFuelLevel()
                end
            end
        end
    end
    turtle.select(1)
    if burned then logRefuel(fuel) end
    return fuel
end

function inv.fuelNeeded(state_)
    return nav.fuelToHome(state_ or st) + (cfg.FUEL_MARGIN or 0)
end

function inv.fuelOk(state_)
    local fuel = turtle.getFuelLevel()
    if fuel == "unlimited" then return true end
    return fuel >= inv.fuelNeeded(state_ or st)
end

-- Inventory detection for one side. Returns info table or nil.
local function probePeripheral(side)
    if not peripheral then return nil end
    local isInv = false
    if peripheral.hasType then
        local ok, r = pcall(peripheral.hasType, side, "inventory")
        isInv = ok and r == true
    end
    if not isInv and peripheral.getType then
        local res = { pcall(peripheral.getType, side) }
        if res[1] then
            for i = 2, #res do
                local t = res[i]
                if type(t) == "string" and (t == "inventory" or t:find("chest") or t:find("barrel")
                        or t:find("shulker")) then
                    isInv = true
                end
            end
        end
    end
    if not isInv then return nil end
    local info = { inventory = true, listed = false, fuel = 0, total = 0 }
    local p = peripheral.wrap and peripheral.wrap(side)
    if p and p.list then
        local ok, items = pcall(p.list)
        if ok and type(items) == "table" then
            info.listed = true
            for _, it in pairs(items) do
                local c = it.count or 0
                info.total = info.total + c
                if fuelValue(it.name) then info.fuel = info.fuel + c end
            end
        end
    end
    return info
end

local function isStorageName(name)
    return type(name) == "string" and (name:find("chest") or name:find("barrel") or name:find("shulker")) ~= nil
end

-- Fallback when no inventory peripheral is visible: inspect all six sides by block name.
local function probeInspect(found)
    local orig = st.facing
    local function rec(side, ok, data)
        if ok and type(data) == "table" and isStorageName(data.name) then
            found[side] = { inventory = true, listed = false, fuel = 0, total = 0, name = data.name }
        end
    end
    rec("top", turtle.inspectUp())
    rec("bottom", turtle.inspectDown())
    for _, side in ipairs({ "front", "left", "right", "back" }) do
        face(sideFacing(side))
        rec(side, turtle.inspect())
    end
    face(orig)
end

function inv.scanHome()
    local result = { dump = nil, fuel = nil, sides = {} }
    local any = false
    -- peripheral sides are relative to the turtle's current facing: probe while facing homeFacing
    local orig = st.facing
    face(st.homeFacing or orig)
    for _, side in ipairs(SIDES) do
        local info = probePeripheral(side)
        if info then result.sides[side] = info; any = true end
    end
    if not any then probeInspect(result.sides) end
    face(orig)

    local found = {}
    for _, side in ipairs(SIDES) do
        if result.sides[side] then found[#found + 1] = side end
    end
    if #found == 1 then
        result.dump = found[1]
    elseif #found > 1 then
        for _, side in ipairs(found) do
            local i = result.sides[side]
            if not result.fuel and i.listed and i.total > 0 and i.fuel * 2 > i.total then
                result.fuel = side
            elseif not result.dump then
                result.dump = side
            end
        end
        if not result.dump then
            -- everything looked like fuel: use the first non-fuel-chest inventory as the dump
            for _, side in ipairs(found) do
                if side ~= result.fuel then result.dump = side; break end
            end
        end
    end
    inv.home = result
    return result
end

-- Dump everything except cfg.FUEL_KEEP fuel items. Never prompts.
function inv.unload()
    if cfg.BURN_COAL and turtle.getFuelLevel() ~= "unlimited" then
        inv.refuel(cfg.FUEL_TARGET or 0)
    end
    local h = inv.scanHome()
    if not h.dump then return false, "no_storage" end
    local failed = atSide(h.dump, function(drop)
        local keep = cfg.FUEL_KEEP or 0
        local bad = false
        for slot = 1, 16 do
            local d = turtle.getItemDetail(slot)
            if d then
                local n = d.count
                if keep > 0 and fuelValue(d.name) then
                    local k = math.min(keep, n)
                    keep = keep - k
                    n = n - k
                end
                if n > 0 then
                    turtle.select(slot)
                    drop(n)
                    if turtle.getItemCount(slot) > d.count - n then bad = true end
                end
            end
        end
        turtle.select(1)
        return bad
    end)
    if failed then return false, "storage_full" end
    return true
end

local function emptySlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then return slot end
    end
    return nil
end

-- At home: burn spare inventory fuel, then pull from the fuel inventory (if any) up to target,
-- and top the reserve back up to cfg.FUEL_KEEP items.
function inv.restockFuel(target)
    local fuel = turtle.getFuelLevel()
    if fuel == "unlimited" then return fuel end
    local limit = fuelLimit()
    if limit and target > limit then target = limit end
    fuel = inv.refuel(target)
    local h = inv.home or inv.scanHome()
    if not h.fuel then return fuel end
    local keep = cfg.FUEL_KEEP or 0
    local burned = false
    atSide(h.fuel, function(drop, suck)
        for _ = 1, 8 do
            local have = fuelItemCount()
            if fuel >= target and have >= keep then break end
            local slot = emptySlot()
            if not slot then break end
            turtle.select(slot)
            local want = 64
            if fuel >= target then want = keep - have end
            if not suck(want) then break end
            local d = turtle.getItemDetail(slot)
            if not d then break end
            local v = fuelValue(d.name)
            if not v then
                drop()          -- not fuel: put it back and stop
                break
            end
            if fuel < target then
                local n = math.min(d.count, math.ceil((target - fuel) / v))
                if limit then n = math.min(n, math.floor((limit - fuel) / v)) end
                if n > 0 and turtle.refuel(n) then
                    burned = true
                    fuel = turtle.getFuelLevel()
                elseif n <= 0 then
                    target = fuel   -- at the fuel limit: stop pulling more
                end
            end
            -- keep only what the reserve needs; return the rest
            local extra = fuelItemCount() - keep
            local cnt = turtle.getItemCount(slot)
            if extra > 0 and cnt > 0 then drop(math.min(extra, cnt)) end
            if fuel >= target and fuelItemCount() >= keep then break end
        end
        turtle.select(1)
    end)
    if burned then logRefuel(fuel) end
    return fuel
end

return inv
