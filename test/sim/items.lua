-- Version: 1.0.0
-- Block/item tables for the simulator: what a block drops, fuel values,
-- stack sizes, falling blocks.

local items = {}

items.AIR = "minecraft:air"

items.UNBREAKABLE = {
    ["minecraft:bedrock"] = true,
    ["minecraft:barrier"] = true,
    ["minecraft:end_portal_frame"] = true,
}

items.FLUID = {
    ["minecraft:water"] = true,
    ["minecraft:lava"] = true,
}

-- hangs from the block above; falls when that support is removed
items.HANGING = {
    ["minecraft:pointed_dripstone"] = true,
}

items.FALLING = {
    ["minecraft:gravel"] = true,
    ["minecraft:sand"] = true,
    ["minecraft:red_sand"] = true,
}

local DROPS = {
    ["minecraft:stone"] = { "minecraft:cobblestone", 1 },
    ["minecraft:deepslate"] = { "minecraft:cobbled_deepslate", 1 },
    ["minecraft:grass_block"] = { "minecraft:dirt", 1 },
    ["minecraft:coal_ore"] = { "minecraft:coal", 1 },
    ["minecraft:deepslate_coal_ore"] = { "minecraft:coal", 1 },
    ["minecraft:iron_ore"] = { "minecraft:raw_iron", 1 },
    ["minecraft:deepslate_iron_ore"] = { "minecraft:raw_iron", 1 },
    ["minecraft:copper_ore"] = { "minecraft:raw_copper", 2, 5 },
    ["minecraft:deepslate_copper_ore"] = { "minecraft:raw_copper", 2, 5 },
    ["minecraft:gold_ore"] = { "minecraft:raw_gold", 1 },
    ["minecraft:deepslate_gold_ore"] = { "minecraft:raw_gold", 1 },
    ["minecraft:redstone_ore"] = { "minecraft:redstone", 4, 5 },
    ["minecraft:deepslate_redstone_ore"] = { "minecraft:redstone", 4, 5 },
    ["minecraft:lapis_ore"] = { "minecraft:lapis_lazuli", 4, 9 },
    ["minecraft:deepslate_lapis_ore"] = { "minecraft:lapis_lazuli", 4, 9 },
    ["minecraft:budding_amethyst"] = { nil, 0 },
    ["minecraft:amethyst_cluster"] = { "minecraft:amethyst_shard", 4 },
    ["minecraft:pointed_dripstone"] = { "minecraft:pointed_dripstone", 1 },
    ["minecraft:diamond_ore"] = { "minecraft:diamond", 1 },
    ["minecraft:deepslate_diamond_ore"] = { "minecraft:diamond", 1 },
    ["minecraft:emerald_ore"] = { "minecraft:emerald", 1 },
    ["minecraft:deepslate_emerald_ore"] = { "minecraft:emerald", 1 },
    ["minecraft:nether_quartz_ore"] = { "minecraft:quartz", 1 },
    ["minecraft:nether_gold_ore"] = { "minecraft:gold_nugget", 3 },
}

-- Returns item name and count dropped when the block is dug (name nil = nothing).
-- Ranged drops use items.rng (seeded per scenario by sim.reset).
items.rng = math.random
function items.drop(name)
    local d = DROPS[name]
    if d then
        if d[3] then return d[1], items.rng(d[2], d[3]) end
        return d[1], d[2]
    end
    return name, 1
end

items.FUEL = {
    ["minecraft:coal"] = 80,
    ["minecraft:charcoal"] = 80,
    ["minecraft:coal_block"] = 800,
    ["minecraft:blaze_rod"] = 120,
    ["minecraft:lava_bucket"] = 1000,
    ["minecraft:stick"] = 5,
}

function items.fuelValue(name)
    if items.FUEL[name] then return items.FUEL[name] end
    if name:find("_planks$") or name:find("_log$") then return 15 end
    return nil
end

local STACK = {
    ["minecraft:lava_bucket"] = 1,
    ["minecraft:water_bucket"] = 1,
    ["minecraft:bucket"] = 16,
    ["minecraft:ender_pearl"] = 16,
    ["minecraft:diamond_pickaxe"] = 1,
}

function items.maxStack(name)
    return STACK[name] or 64
end

-- Items that cannot be placed as a block.
local NOT_PLACEABLE = {
    ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:raw_iron"] = true,
    ["minecraft:raw_copper"] = true, ["minecraft:raw_gold"] = true, ["minecraft:diamond"] = true,
    ["minecraft:emerald"] = true, ["minecraft:lapis_lazuli"] = true, ["minecraft:quartz"] = true,
    ["minecraft:gold_nugget"] = true, ["minecraft:bucket"] = true, ["minecraft:lava_bucket"] = true,
    ["minecraft:stick"] = true, ["minecraft:blaze_rod"] = true,
}

function items.placeable(name)
    return not NOT_PLACEABLE[name]
end

function items.tags(name)
    local tags = {}
    if name:find("_ore$") or name == "minecraft:ancient_debris" then
        tags["c:ores"] = true
        tags["forge:ores"] = true
        local fam = name:gsub("^.*:", ""):gsub("^deepslate_", ""):gsub("^nether_", ""):gsub("_ore$", "")
        tags["minecraft:" .. fam .. "_ores"] = true
        tags["c:ores/" .. fam] = true
    end
    if name:find("deepslate") then tags["minecraft:deepslate_ore_replaceables"] = true end
    if name == "minecraft:stone" or name == "minecraft:granite" or name == "minecraft:diorite"
        or name == "minecraft:andesite" or name == "minecraft:tuff" then
        tags["minecraft:stone_ore_replaceables"] = true
    end
    if name:find("pickaxe") == nil and not items.FLUID[name] then tags["minecraft:mineable/pickaxe"] = true end
    if name == "minecraft:raw_iron_block" or name == "minecraft:raw_copper_block" or name == "minecraft:raw_gold_block" then
        tags["c:storage_blocks"] = true
    end
    if name == "minecraft:stone" or name == "minecraft:deepslate" or name == "minecraft:tuff"
        or name == "minecraft:granite" or name == "minecraft:diorite" or name == "minecraft:andesite" then
        tags["minecraft:base_stone_overworld"] = true
    end
    return tags
end

return items
