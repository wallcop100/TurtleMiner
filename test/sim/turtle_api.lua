-- Version: 1.0.0
-- Fake `turtle` API bound to a turtle record living in a sim world.
--
-- Every action calls c:check{kind="turtle", op=, when="before"} before it
-- touches the world and c:check{kind="turtle", op=, when="after", ok=, err=}
-- after, so a test can crash the computer on either side of the action.
-- Actions then yield until a "turtle_response" event, like the real API, so
-- other coroutines (net loop) run while the turtle is busy.

local items = require("items")

local M = {}

local DIRS = {
    [0] = { x = 0, y = 0, z = -1 },
    [1] = { x = 1, y = 0, z = 0 },
    [2] = { x = 0, y = 0, z = 1 },
    [3] = { x = -1, y = 0, z = 0 },
}
M.DIRS = DIRS

local MOVE_TIME = 0.4
local DIG_TIME = 0.4
local FAST_TIME = 0.05

function M.offset(t, which)
    local p = t.pos
    if which == "up" then return p.x, p.y + 1, p.z end
    if which == "down" then return p.x, p.y - 1, p.z end
    local f = t.facing
    if which == "back" then f = (f + 2) % 4 end
    if which == "left" then f = (f + 3) % 4 end
    if which == "right" then f = (f + 1) % 4 end
    local d = DIRS[f]
    return p.x + d.x, p.y + d.y, p.z + d.z
end

local function hasPickaxe(t)
    for _, side in ipairs({ "left", "right" }) do
        local e = t.equip[side]
        if e and (e:find("pickaxe") or e:find("mining")) then return true end
    end
    return false
end

-- Store items into the turtle inventory starting at the selected slot.
-- Returns the number that did not fit.
function M.store(t, name, count)
    local max = items.maxStack(name)
    local function pass(wantEmpty)
        for i = 0, 15 do
            if count <= 0 then return end
            local s = ((t.selected - 1 + i) % 16) + 1
            local it = t.inv[s]
            if wantEmpty and not it then
                local n = math.min(count, max)
                t.inv[s] = { name = name, count = n }
                count = count - n
            elseif not wantEmpty and it and it.name == name and it.count < max then
                local n = math.min(count, max - it.count)
                it.count = it.count + n
                count = count - n
            end
        end
    end
    pass(false)
    pass(true)
    return count
end

-- Insert into a chest inventory {size, slots}; returns amount inserted.
function M.insertInto(inv, name, count)
    local max = items.maxStack(name)
    local moved = 0
    for s = 1, inv.size do
        local it = inv.slots[s]
        if it and it.name == name and it.count < max then
            local n = math.min(count - moved, max - it.count)
            it.count = it.count + n
            moved = moved + n
        end
        if moved >= count then return moved end
    end
    for s = 1, inv.size do
        if not inv.slots[s] then
            local n = math.min(count - moved, max)
            inv.slots[s] = { name = name, count = n }
            moved = moved + n
        end
        if moved >= count then return moved end
    end
    return moved
end

function M.build(sim, c, t)
    local w = t.world
    local api = {}

    local function act(op, fn, delay)
        c:guard()
        local before = { kind = "turtle", op = op, when = "before", turtle = t, pos = sim.copyPos(t.pos),
                         facing = t.facing, fuel = t.fuel }
        if c:check(before) then c:halt(before) end
        local r = table.pack(fn())
        t.ops = t.ops + 1
        t.opCounts[op] = (t.opCounts[op] or 0) + 1
        local after = { kind = "turtle", op = op, when = "after", ok = r[1], err = r[2], turtle = t,
                        pos = sim.copyPos(t.pos), facing = t.facing, fuel = t.fuel }
        for _, hook in ipairs(t.hooks) do hook(after) end
        if c:check(after) then c:halt(after) end
        sim.waitTask(c, delay or FAST_TIME)
        return table.unpack(r, 1, r.n)
    end

    local function unlimited() return t.fuel == "unlimited" end

    local function move(op, which)
        return act(op, function()
            if not unlimited() and t.fuel <= 0 then return false, "Out of fuel" end
            local x, y, z = M.offset(t, which)
            if y < w.minY then return false, "Too low to move" end
            if y > w.maxY then return false, "Too high to move" end
            if not w:passable(x, y, z) then
                local o = w:turtleAt(x, y, z)
                if o then
                    -- army accounting: a failed move into another turtle (frozen or not)
                    w.collisions[#w.collisions + 1] = { time = sim.now, by = t.id, with = o.id, x = x, y = y, z = z,
                        frozen = o.computer.frozen and true or false }
                end
                return false, "Movement obstructed"
            end
            local old = sim.copyPos(t.pos)
            t.prevPos, t.prevFacing = old, t.facing
            t.pos = { x = x, y = y, z = z }
            if not unlimited() then t.fuel = t.fuel - 1 end
            t.moves = t.moves + 1
            w:fall(old.x, old.y, old.z)
            return true
        end, MOVE_TIME)
    end

    api.forward = function() return move("forward", "front") end
    api.back = function() return move("back", "back") end
    api.up = function() return move("up", "up") end
    api.down = function() return move("down", "down") end

    local function turn(op, d)
        return act(op, function()
            t.prevFacing = t.facing
            t.facing = (t.facing + d) % 4
            return true
        end, MOVE_TIME)
    end
    api.turnLeft = function() return turn("turnLeft", 3) end
    api.turnRight = function() return turn("turnRight", 1) end

    local function dig(op, which)
        return act(op, function()
            local x, y, z = M.offset(t, which)
            local cell = w:cell(x, y, z)
            if cell.name == items.AIR or items.FLUID[cell.name] then
                if w:dugBy(x, y, z) ~= nil and w:dugBy(x, y, z) ~= t.id then
                    w.redigTries[#w.redigTries + 1] = { time = sim.now, by = t.id, first = w:dugBy(x, y, z), x = x, y = y, z = z }
                end
                return false, "Nothing to dig here"
            end
            if w:turtleAt(x, y, z) then return false, "Unbreakable block" end
            if items.UNBREAKABLE[cell.name] then return false, "Unbreakable block" end
            if not hasPickaxe(t) then return false, "No tool to dig with" end
            local removed = w:remove(x, y, z, t.id)
            local name, count = items.drop(removed.name)
            if name and count > 0 then
                local left = M.store(t, name, count)
                if left > 0 then w:spill(name, left, t.pos.x, t.pos.y, t.pos.z) end
            end
            if removed.inv then
                for _, it in pairs(removed.inv.slots) do w:spill(it.name, it.count, x, y, z) end
            end
            t.digs = t.digs + 1
            return true
        end, DIG_TIME)
    end
    api.dig = function() return dig("dig", "front") end
    api.digUp = function() return dig("digUp", "up") end
    api.digDown = function() return dig("digDown", "down") end

    local function attack(op, which)
        return act(op, function()
            local x, y, z = M.offset(t, which)
            local cell = w:cell(x, y, z)
            if w:mobAt(x, y, z) then
                cell.mob = cell.mob - 1
                if cell.mob <= 0 then cell.mob = nil end
                return true
            end
            return false, "Nothing to attack here"
        end)
    end
    api.attack = function() return attack("attack", "front") end
    api.attackUp = function() return attack("attackUp", "up") end
    api.attackDown = function() return attack("attackDown", "down") end

    -- detect / inspect / compare are instant in CC but still go through act()
    -- so tests can count them; they take one tick.
    local function detect(op, which)
        return act(op, function()
            local x, y, z = M.offset(t, which)
            if w:turtleAt(x, y, z) then return true end
            local n = w:get(x, y, z)
            return n ~= items.AIR and not items.FLUID[n]
        end)
    end
    api.detect = function() return detect("detect", "front") end
    api.detectUp = function() return detect("detectUp", "up") end
    api.detectDown = function() return detect("detectDown", "down") end

    local function inspect(op, which)
        return act(op, function()
            local x, y, z = M.offset(t, which)
            if w:turtleAt(x, y, z) then
                return true, { name = "computercraft:turtle_normal", state = { facing = "north" }, tags = {} }
            end
            local name = w:get(x, y, z)
            if name == items.AIR then return false, "No block to inspect" end
            local state = {}
            if items.FLUID[name] then state.level = 0 end
            return true, { name = name, state = state, tags = items.tags(name) }
        end)
    end
    api.inspect = function() return inspect("inspect", "front") end
    api.inspectUp = function() return inspect("inspectUp", "up") end
    api.inspectDown = function() return inspect("inspectDown", "down") end

    local function compare(op, which)
        return act(op, function()
            local x, y, z = M.offset(t, which)
            local it = t.inv[t.selected]
            local name = w:get(x, y, z)
            if name == items.AIR then return it == nil end
            return it ~= nil and it.name == name
        end)
    end
    api.compare = function() return compare("compare", "front") end
    api.compareUp = function() return compare("compareUp", "up") end
    api.compareDown = function() return compare("compareDown", "down") end

    local function place(op, which)
        return act(op, function()
            local it = t.inv[t.selected]
            if not it then return false, "No items to place" end
            local x, y, z = M.offset(t, which)
            if not items.placeable(it.name) or not w:passable(x, y, z) then return false, "Cannot place block here" end
            w:set(x, y, z, it.name)
            it.count = it.count - 1
            if it.count <= 0 then t.inv[t.selected] = nil end
            return true
        end)
    end
    api.place = function() return place("place", "front") end
    api.placeUp = function() return place("placeUp", "up") end
    api.placeDown = function() return place("placeDown", "down") end

    local function drop(op, which, count)
        return act(op, function()
            local it = t.inv[t.selected]
            if not it then return false, "No items to drop" end
            count = math.min(count or it.count, it.count)
            if count <= 0 then return false, "No items to drop" end
            local x, y, z = M.offset(t, which)
            local inv = w:inventoryAt(x, y, z)
            if inv then
                local moved = M.insertInto(inv, it.name, count)
                if moved == 0 then return false, "No space for items" end
                it.count = it.count - moved
            else
                w:spill(it.name, count, x, y, z)
                it.count = it.count - count
            end
            if it.count <= 0 then t.inv[t.selected] = nil end
            return true
        end)
    end
    api.drop = function(n) return drop("drop", "front", n) end
    api.dropUp = function(n) return drop("dropUp", "up", n) end
    api.dropDown = function(n) return drop("dropDown", "down", n) end

    local function suck(op, which, count)
        return act(op, function()
            local x, y, z = M.offset(t, which)
            local inv = w:inventoryAt(x, y, z)
            if not inv then return false, "No items to take" end
            for s = 1, inv.size do
                local it = inv.slots[s]
                if it then
                    local want = math.min(count or 64, it.count)
                    local left = M.store(t, it.name, want)
                    local took = want - left
                    if took == 0 then return false, "No space for items" end
                    it.count = it.count - took
                    if it.count <= 0 then inv.slots[s] = nil end
                    return true
                end
            end
            return false, "No items to take"
        end)
    end
    api.suck = function(n) return suck("suck", "front", n) end
    api.suckUp = function(n) return suck("suckUp", "up", n) end
    api.suckDown = function(n) return suck("suckDown", "down", n) end

    local function checkSlot(s, argn)
        if s == nil then return t.selected end
        if type(s) ~= "number" or s < 1 or s > 16 or s ~= math.floor(s) then
            error("bad argument #" .. (argn or 1) .. " (Slot out of range)", 3)
        end
        return s
    end

    api.select = function(s)
        c:guard()
        s = checkSlot(s)
        t.selected = s
        return true
    end
    api.getSelectedSlot = function() c:guard(); return t.selected end
    api.getItemCount = function(s)
        c:guard()
        local it = t.inv[checkSlot(s)]
        return it and it.count or 0
    end
    api.getItemSpace = function(s)
        c:guard()
        local it = t.inv[checkSlot(s)]
        if not it then return 64 end
        return items.maxStack(it.name) - it.count
    end
    api.getItemDetail = function(s, detailed)
        c:guard()
        local it = t.inv[checkSlot(s)]
        if not it then return nil end
        local r = { name = it.name, count = it.count }
        if detailed then
            r.displayName = it.name:gsub("^.*:", "")
            r.maxCount = items.maxStack(it.name)
            r.tags = {}
            if items.fuelValue(it.name) then r.tags["minecraft:coals"] = it.name:find("coal") and true or nil end
        end
        return r
    end
    api.getFuelLevel = function() c:guard(); return t.fuel end
    api.getFuelLimit = function() c:guard(); if t.fuel == "unlimited" then return "unlimited" end return t.fuelLimit end

    api.refuel = function(count)
        return act("refuel", function()
            local it = t.inv[t.selected]
            if not it then return false, "No items to combust" end
            local value = items.fuelValue(it.name)
            if not value then return false, "Items not combustible" end
            if unlimited() then return true end
            local limit = math.min(count or it.count, it.count)
            if limit == 0 then return true end
            local space = t.fuelLimit - t.fuel
            local need = math.ceil(space / value)
            if limit > need then limit = need end
            t.fuel = math.min(t.fuelLimit, t.fuel + limit * value)
            it.count = it.count - limit
            if it.count <= 0 then t.inv[t.selected] = nil end
            if it.name == "minecraft:lava_bucket" and limit > 0 then
                local left = M.store(t, "minecraft:bucket", limit)
                if left > 0 then w:spill("minecraft:bucket", left, t.pos.x, t.pos.y, t.pos.z) end
            end
            t.refuels[#t.refuels + 1] = { time = sim.now, fuel = t.fuel, pos = sim.copyPos(t.pos), items = limit }
            return true
        end)
    end

    api.transferTo = function(slot, count)
        slot = checkSlot(slot)
        return act("transferTo", function()
            local it = t.inv[t.selected]
            if not it then return true end
            count = math.min(count or it.count, it.count)
            local dst = t.inv[slot]
            if slot == t.selected then return true end
            if dst and dst.name ~= it.name then return false, "No space for items" end
            local max = items.maxStack(it.name)
            local n = math.min(count, max - (dst and dst.count or 0))
            if n <= 0 then return false, "No space for items" end
            if dst then dst.count = dst.count + n else t.inv[slot] = { name = it.name, count = n } end
            it.count = it.count - n
            if it.count <= 0 then t.inv[t.selected] = nil end
            return true
        end)
    end

    api.compareTo = function(slot)
        slot = checkSlot(slot)
        c:guard()
        local a, b = t.inv[t.selected], t.inv[slot]
        if a == nil or b == nil then return a == b end
        return a.name == b.name
    end

    local function upgradeOk(name)
        return name:find("pickaxe") or name:find("modem") or name:find("crafting_table")
            or name:find("sword") or name:find("_axe") or name:find("shovel") or name:find("hoe")
            or name:find("speaker") or name:find("chunk")
    end
    local function equip(side)
        return act("equip" .. side, function()
            local it = t.inv[t.selected]
            if it and not upgradeOk(it.name) then return false, "Not a valid upgrade" end
            local old = t.equip[side]
            t.equip[side] = it and it.name or nil
            if it then
                it.count = it.count - 1
                if it.count <= 0 then t.inv[t.selected] = nil end
            end
            if old then
                local left = M.store(t, old, 1)
                if left > 0 then w:spill(old, 1, t.pos.x, t.pos.y, t.pos.z) end
            end
            return true
        end)
    end
    api.equipLeft = function() return equip("left") end
    api.equipRight = function() return equip("right") end
    api.getEquippedLeft = function() c:guard(); local e = t.equip.left; return e and { name = e, count = 1 } or nil end
    api.getEquippedRight = function() c:guard(); local e = t.equip.right; return e and { name = e, count = 1 } or nil end
    api.craft = function() return false, "No crafting table" end

    return api
end

return M
