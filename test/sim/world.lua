-- Version: 1.0.0
-- Voxel world for the simulator.
-- Default fill: stone; bedrock at y <= bedrockY (-60). Cells that were set
-- explicitly live in `cells`. Chests carry an inventory {size=, slots={}}.
-- Mobs are an optional per-cell "attack needed N times" counter.

local items = require("items")

local World = {}
World.__index = World

local AIR = items.AIR

local function key(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end
World.key = key

local function deepcopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local r = {}
    seen[v] = r
    for k, val in pairs(v) do r[deepcopy(k, seen)] = deepcopy(val, seen) end
    return r
end
World.deepcopy = deepcopy

function World.new(opts)
    opts = opts or {}
    local w = setmetatable({}, World)
    w.cells = {}
    w.default = opts.default or "minecraft:stone"
    w.bedrockY = opts.bedrockY or -60
    -- jagged bedrock: top of bedrock varies per column between -64 and -60
    w.jagged = opts.jaggedBedrock
    w.seed = opts.seed or 1
    -- optional generator(x,y,z) -> name|nil for cells not explicitly set
    w.gen = opts.gen
    w.minY = opts.minY or -64
    w.maxY = opts.maxY or 319
    w.turtles = {}      -- list of turtle records living in this world
    w.digLog = {}       -- {x,y,z,name,by,time}
    w.dropped = {}      -- items spilled into the world {name,count,x,y,z}
    w.clock = opts.clock or function() return 0 end
    return w
end

-- Raw cell: returns a table {name=..., inv=?, mob=?}. Generated cells are not stored.
function World:bedrockTop(x, z)
    if not self.jagged then return self.bedrockY end
    local h = (x * 73856093 ~ z * 19349663 ~ self.seed * 83492791) % 5
    return -64 + h
end

function World:cell(x, y, z)
    local c = self.cells[key(x, y, z)]
    if c then return c end
    if y <= self:bedrockTop(x, z) then return { name = "minecraft:bedrock" } end
    if self.gen then
        local n = self.gen(x, y, z)
        if n then return { name = n } end
    end
    return { name = self.default }
end

function World:get(x, y, z)
    return self:cell(x, y, z).name
end

function World:set(x, y, z, name)
    if name == nil or name == "air" then name = AIR end
    self.cells[key(x, y, z)] = { name = name }
end

function World:isAir(x, y, z)
    return self:get(x, y, z) == AIR
end

-- Place a chest. `contents` is a slot table {[slot]={name=,count=}} or a list.
function World:chest(x, y, z, contents, opts)
    opts = opts or {}
    local slots = {}
    for i, it in pairs(contents or {}) do
        slots[i] = { name = it.name or it[1], count = it.count or it[2] or 1 }
    end
    self.cells[key(x, y, z)] = {
        name = opts.name or "minecraft:chest",
        inv = { size = opts.size or 27, slots = slots },
    }
end

-- Live slot table of the chest at x,y,z (nil if no inventory there).
function World:chestContents(x, y, z)
    local c = self.cells[key(x, y, z)]
    return c and c.inv and c.inv.slots or nil
end

function World:setChestContents(x, y, z, slots)
    local c = self.cells[key(x, y, z)]
    assert(c and c.inv, "no chest at " .. key(x, y, z))
    c.inv.slots = deepcopy(slots or {})
end

function World:inventoryAt(x, y, z)
    local c = self.cells[key(x, y, z)]
    return c and c.inv or nil
end

-- Count of an item (or all items if name nil) in the chest.
function World:chestCount(x, y, z, name)
    local n = 0
    for _, it in pairs(self:chestContents(x, y, z) or {}) do
        if name == nil or it.name == name then n = n + it.count end
    end
    return n
end

-- A mob standing in an air cell that needs `hits` attacks to clear
-- (math.huge = never dies). With `leaveAt` (sim time) it walks off by itself then.
function World:mob(x, y, z, hits, leaveAt)
    self.cells[key(x, y, z)] = { name = AIR, mob = hits or 1, mobLeaveAt = leaveAt }
end

function World:mobAt(x, y, z)
    local c = self.cells[key(x, y, z)]
    if not c or not c.mob or c.mob <= 0 then return false end
    if c.mobLeaveAt and self.clock() >= c.mobLeaveAt then c.mob = nil; return false end
    return true
end

-- Column of falling blocks with its lowest block at y.
function World:gravelColumn(x, y, z, height, name)
    for i = 0, height - 1 do self:set(x, y + i, z, name or "minecraft:gravel") end
end

-- Fluid source block (turtles pass through; dig says "Nothing to dig here").
function World:fluid(x, y, z, name)
    self:set(x, y, z, name or "minecraft:lava")
end

function World:fill(x1, y1, z1, x2, y2, z2, name)
    for x = math.min(x1, x2), math.max(x1, x2) do
        for y = math.min(y1, y2), math.max(y1, y2) do
            for z = math.min(z1, z2), math.max(z1, z2) do
                self:set(x, y, z, name)
            end
        end
    end
end

function World:turtleAt(x, y, z)
    for _, t in ipairs(self.turtles) do
        if t.pos.x == x and t.pos.y == y and t.pos.z == z then return t end
    end
    return nil
end

-- Can a turtle move into this cell?
function World:passable(x, y, z)
    if y < self.minY or y > self.maxY then return false end
    local c = self:cell(x, y, z)
    if c.name ~= AIR and not items.FLUID[c.name] then return false end
    if self:mobAt(x, y, z) then return false end
    if self:turtleAt(x, y, z) then return false end
    return true
end

-- Hanging blocks (pointed dripstone) whose support above (x,y,z) just vanished drop
-- straight down until they land.
function World:dropHanging(x, y, z)
    local yy = y - 1
    while items.HANGING[self:get(x, yy, z)] do
        local name = self:get(x, yy, z)
        self:set(x, yy, z, AIR)
        local ly = yy
        while ly - 1 >= self.minY and self:isAir(x, ly - 1, z) and not self:turtleAt(x, ly - 1, z) do ly = ly - 1 end
        if self:turtleAt(x, ly - 1, z) or ly == yy then
            self:spill(name, 1, x, ly, z)
        else
            self:set(x, ly, z, name)
        end
        yy = yy - 1
    end
end

-- Gravity: cell x,y,z just became empty. Falling blocks above shift down by one.
function World:fall(x, y, z)
    local yy = y
    while true do
        local above = self:cell(x, yy + 1, z)
        if not items.FALLING[above.name] then break end
        if not self:isAir(x, yy, z) or self:turtleAt(x, yy, z) then break end
        self:set(x, yy, z, above.name)
        self:set(x, yy + 1, z, AIR)
        yy = yy + 1
    end
end

-- Remove a block (dig). Returns the removed cell.
function World:remove(x, y, z, by)
    local c = self:cell(x, y, z)
    self.cells[key(x, y, z)] = { name = AIR }
    self.digLog[#self.digLog + 1] = { x = x, y = y, z = z, name = c.name, by = by, time = self.clock() }
    self:fall(x, y, z)
    self:dropHanging(x, y, z)
    return c
end

function World:spill(name, count, x, y, z)
    self.dropped[#self.dropped + 1] = { name = name, count = count, x = x, y = y, z = z }
end

-- Set of dug cells (key -> first digLog entry), optionally filtered by turtle id.
function World:dugCells(by)
    local r = {}
    for _, d in ipairs(self.digLog) do
        if not d.rollback and (by == nil or d.by == by) then
            local k = key(d.x, d.y, d.z)
            if not r[k] then r[k] = d end
        end
    end
    return r
end

function World:snapshot()
    return { cells = deepcopy(self.cells), digN = #self.digLog, droppedN = #self.dropped }
end

function World:restore(s)
    self.cells = deepcopy(s.cells)
    -- logs are history of what happened; keep them but mark the rollback
    self.digLog[#self.digLog + 1] = { rollback = true, time = self.clock(), x = 0, y = 0, z = 0, name = "#rollback" }
end

return World
