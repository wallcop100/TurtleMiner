-- Version: 1.0.2
-- TurtleMiner inventory and fuel (WP-B).
-- Refuel with a reserve, trash dropping, home storage detection, unload, fuel restock.
-- Never prompts. Every turn it makes is undone before returning.

local inv = {}

local st, cfg, nav

local SIDES = { "front", "top", "bottom", "left", "right", "back" }
-- Preference for the dump when nothing tells the inventories apart: behind first.
local DUMP_ORDER = { "back", "front", "left", "right", "bottom", "top" }
-- Horizontal sides in turning order (one way round from front).
local ROUND = { "front", "right", "back", "left" }

-- Fuel value per item (by name without namespace). Lava buckets are deliberately not handled.
local FUEL_VALUE = { coal = 80, charcoal = 80, coal_block = 800, blaze_rod = 120 }

local inspectCache = nil   -- horizontal side -> block name|false, from the last full scan

local function baseName(name)
    return name:match(":(.+)$") or name
end

local function fuelValue(name)
    if type(name) ~= "string" then return nil end
    return FUEL_VALUE[baseName(name)]
end
inv.fuelValue = fuelValue

-- Storage blocks only: chests (incl. trapped), barrels, shulker boxes and modded blocks whose
-- name says chest/barrel/crate. Furnaces, hoppers, droppers etc. are inventories but not storage.
local function isStorageName(name)
    if type(name) ~= "string" then return false end
    local b = baseName(name):lower()
    return b:find("chest", 1, true) ~= nil or b:find("barrel", 1, true) ~= nil
        or b:find("crate", 1, true) ~= nil or b:find("shulker_box", 1, true) ~= nil
end
inv.isStorageName = isStorageName

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

-- Burn n items from slot and journal the new level right after this one call (an R line per
-- turtle.refuel, so a crash between two refuels never leaves fuel the journal can't explain).
local function burn(slot, n)
    turtle.select(slot)
    local ok = turtle.refuel(n)
    local fuel = turtle.getFuelLevel()
    logRefuel(fuel)
    return ok, fuel
end

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

local function inspectName(fn)
    local ok, data = fn()
    if ok and type(data) == "table" and type(data.name) == "string" then return data.name end
    return false
end

-- Run fn(drop, suck) with the turtle facing `side`; restores the original facing afterwards.
-- Checks the block there first (no drop into the world if the inventory is gone):
-- returns nil, "missing" then.
local function atSide(side, fn, info)
    local orig = st.facing
    local drop, suck, insp
    if side == "top" then
        drop, suck, insp = turtle.dropUp, turtle.suckUp, turtle.inspectUp
    elseif side == "bottom" then
        drop, suck, insp = turtle.dropDown, turtle.suckDown, turtle.inspectDown
    else
        drop, suck, insp = turtle.drop, turtle.suck, turtle.inspect
        face(sideFacing(side))
    end
    local name = inspectName(insp)
    local here = name and (name == (info and info.name) or isStorageName(name))
    if not here then
        face(orig)
        return nil, "missing"
    end
    local a, b = fn(drop, suck)
    face(orig)
    return a, b
end

function inv.init(state_, cfg_, nav_)
    st, cfg, nav = state_, cfg_, nav_
    inv.home = nil
    inspectCache = nil
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
-- opts.emergency = true burns the reserve too (stranded: the reserve is there for this).
function inv.refuel(target, opts)
    local fuel = turtle.getFuelLevel()
    if fuel == "unlimited" then return fuel end
    local limit = fuelLimit()
    if limit and target > limit then target = limit end
    if fuel >= target then return fuel end
    local keep = (opts and opts.emergency) and 0 or (cfg.FUEL_KEEP or 0)
    local spare = fuelItemCount() - keep
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
                local ok
                ok, fuel = burn(slot, n)
                if ok then spare = spare - n end
            end
        end
    end
    turtle.select(1)
    return fuel
end

-- Fuel to get home from where the turtle is: the real tunnel route (mine.routeHomeLength,
-- including the backtrack out of a vein) when mine.lua is initialised, else Manhattan;
-- plus cfg.FUEL_MARGIN.
function inv.fuelNeeded(state_)
    local s = state_ or st
    local d
    local okM, mine = pcall(require, "mine")
    if okM and type(mine) == "table" and type(mine.routeHomeLength) == "function" then
        local ok, n
        if s == st then ok, n = pcall(mine.routeHomeLength)
        else ok, n = pcall(mine.routeHomeLength, s.pos) end
        if ok and type(n) == "number" then d = n end
    end
    if not d then d = nav.fuelToHome(s) end
    return d + (cfg.FUEL_MARGIN or 0)
end

function inv.fuelOk(state_)
    local fuel = turtle.getFuelLevel()
    if fuel == "unlimited" then return true end
    return fuel >= inv.fuelNeeded(state_ or st)
end

-- Peripheral view of one side (turtle facing homeFacing). Returns
--   nil                      nothing there
--   "other"                  a peripheral that is not an inventory (modem, ...) or a non-storage
--                            inventory (furnace, hopper, ...)
--   info                     storage inventory: {inventory, listed, fuel, total, name}
--   "unnamed", info          an inventory whose type names no block: decided by inspect
local function probePeripheral(side)
    if not peripheral or not peripheral.getType then return nil end
    local res = { pcall(peripheral.getType, side) }
    if not res[1] or res[2] == nil then return nil end
    local isInv, name, storage = false, nil, false
    for i = 2, #res do
        local t = res[i]
        if type(t) == "string" then
            if t == "inventory" then
                isInv = true
            elseif t:find(":", 1, true) then
                name = name or t
                if isStorageName(t) then storage = true end
            elseif isStorageName(t) then
                storage = true
            end
        end
    end
    if not isInv and peripheral.hasType then
        local ok, r = pcall(peripheral.hasType, side, "inventory")
        isInv = ok and r == true
    end
    if not isInv and not storage then return "other" end
    if name and not storage then return "other" end
    local info = { inventory = true, listed = false, fuel = 0, total = 0, name = name }
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
    if not storage then return "unnamed", info end
    return info
end

-- Look at the home's six neighbours: peripherals (fuel content via list()) merged with the
-- block names from inspect, so a chest hidden behind an equipped modem is still found.
-- Horizontal sides that have no storage peripheral are inspected by turning (and cached for
-- later calls with opts.cached); top and bottom cost no turn. Restores facing.
function inv.scanHome(opts)
    local fresh = not (opts and opts.cached and inspectCache)
    local result = { dump = nil, fuel = nil, sides = {} }
    local orig = st.facing
    face(st.homeFacing or orig)   -- peripheral sides are relative to the current facing
    local pending = {}            -- side -> info awaiting a name check
    local needLook = {}
    for _, side in ipairs(SIDES) do
        local a, b = probePeripheral(side)
        if type(a) == "table" then
            result.sides[side] = a
        elseif a == "unnamed" then
            pending[side] = b
            needLook[side] = true
        elseif a ~= "other" or side == "left" or side == "right" then
            needLook[side] = true   -- empty, or an upgrade side that may hide a block
        end
    end
    local names = {}
    if needLook.top then names.top = inspectName(turtle.inspectUp) end
    if needLook.bottom then names.bottom = inspectName(turtle.inspectDown) end
    if fresh then inspectCache = {} end
    for _, side in ipairs(ROUND) do
        if needLook[side] then
            if fresh or inspectCache[side] == nil then
                face(sideFacing(side))
                inspectCache[side] = inspectName(turtle.inspect)
            end
            names[side] = inspectCache[side]
        end
    end
    face(orig)
    for side, name in pairs(names) do
        if not result.sides[side] and isStorageName(name) then
            local info = pending[side] or { inventory = true, listed = false, fuel = 0, total = 0 }
            info.name = name
            result.sides[side] = info
        end
    end

    local found = {}
    for _, side in ipairs(DUMP_ORDER) do
        if result.sides[side] then found[#found + 1] = side end
    end
    if #found == 1 then
        result.dump = found[1]
    elseif #found > 1 then
        -- the fuel source is the listable inventory that is mostly fuel; without one (e.g. only
        -- the dump is listable, or nothing is) there is no fuel chest and the dump is the first
        -- inventory in DUMP_ORDER (behind the turtle first)
        for _, side in ipairs(found) do
            local i = result.sides[side]
            if i.listed and i.total > 0 and i.fuel * 2 > i.total then result.fuel = side; break end
        end
        for _, side in ipairs(found) do
            if side ~= result.fuel then result.dump = side; break end
        end
    end
    inv.home = result
    return result
end

-- Drop items at `side`. `pick(name, count)` returns how many of that stack to drop.
-- Returns true if something could not be dropped (inventory full), nil, "missing" if the
-- inventory is no longer there.
local function dropAt(side, pick)
    local h = inv.home
    return atSide(side, function(drop)
        local bad = false
        for slot = 1, 16 do
            local d = turtle.getItemDetail(slot)
            if d then
                local n = pick(d.name, d.count)
                if n > 0 then
                    turtle.select(slot)
                    drop(n)
                    if turtle.getItemCount(slot) > d.count - n then bad = true end
                end
            end
        end
        turtle.select(1)
        return bad
    end, h and h.sides[side])
end

local function doUnload(h)
    -- surplus fuel -> fuel inventory (whatever does not fit falls through to the dump)
    if h.fuel then
        local keep = cfg.FUEL_KEEP or 0
        dropAt(h.fuel, function(name, count)
            if not fuelValue(name) then return 0 end
            local k = math.min(keep, count)
            keep = keep - k
            return count - k
        end)
    end
    local keep = cfg.FUEL_KEEP or 0
    return dropAt(h.dump, function(name, count)
        if keep > 0 and fuelValue(name) then
            local k = math.min(keep, count)
            keep = keep - k
            return count - k
        end
        return count
    end)
end

-- Dump everything except cfg.FUEL_KEEP fuel items. Never prompts.
-- Mined fuel is burned first (BURN_COAL); fuel beyond the reserve goes back to the fuel
-- inventory when there is one, so coal never ends up in the storage chest.
function inv.unload()
    if cfg.BURN_COAL and turtle.getFuelLevel() ~= "unlimited" then
        inv.refuel(cfg.FUEL_TARGET or 0)
    end
    local h = inv.scanHome({ cached = true })
    if not h.dump then h = inv.scanHome() end
    if not h.dump then return false, "no_storage" end
    local failed, why = doUnload(h)
    if why == "missing" then
        h = inv.scanHome()
        if not h.dump then return false, "no_storage" end
        failed, why = doUnload(h)
        if why == "missing" then return false, "no_storage" end
    end
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
    local h = inv.home or inv.scanHome({ cached = true })
    if not h.fuel then return fuel end
    local keep = cfg.FUEL_KEEP or 0
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
                if n > 0 then
                    local _
                    _, fuel = burn(slot, n)
                    turtle.select(slot)
                else
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
    end, h.sides and h.sides[h.fuel])
    return fuel
end

return inv
