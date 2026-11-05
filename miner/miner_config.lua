-- Version: 2.1.0
-- Enhanced Mining Configuration with Vein Mining Support

local CONFIG = {
    MINING_PATTERN = "branch",   -- "branch", "spiral", or "vertical"
    BRANCH_LENGTH = 16,          -- Length of each branch
    BRANCH_SPACING = 3,          -- Blocks between branches
    VERTICAL_DEPTH = 64,         -- Depth for vertical mining
    AUTO_DESCEND = true,         -- Automatically descend to target Y level
    TARGET_Y_LEVEL = -59,        -- Optimal for diamonds in 1.21.1 (can be changed remotely)
    FUEL_THRESHOLD = 1000,       -- Top up from carried fuel when below this
    FUEL_RESERVE_MULTIPLIER = 3, -- Reserve 3x distance for safety
    MIN_FUEL_TO_START = 500,     -- Minimum fuel to begin operations
    MAX_STUCK_ATTEMPTS = 10,     -- Max attempts to get unstuck
    CHECK_SURROUNDING = true,    -- Check blocks around while mining
    MINE_ENTIRE_VEINS = true,    -- Mine entire ore veins when found (NEW)
    STATUS_INTERVAL = 10,        -- Send status every N seconds (reduced for more updates)
    
    -- Ore types for focused mining (can be changed remotely)
    VALUABLE_ORES = {
        "minecraft:diamond_ore",
        "minecraft:deepslate_diamond_ore",
        "minecraft:emerald_ore",
        "minecraft:deepslate_emerald_ore",
        "minecraft:gold_ore",
        "minecraft:deepslate_gold_ore",
        "minecraft:iron_ore",
        "minecraft:deepslate_iron_ore",
        "minecraft:redstone_ore",
        "minecraft:deepslate_redstone_ore",
        "minecraft:lapis_ore",
        "minecraft:deepslate_lapis_ore",
        "minecraft:copper_ore",
        "minecraft:deepslate_copper_ore",
        "minecraft:coal_ore",
        "minecraft:deepslate_coal_ore",
        "minecraft:ancient_debris",
        "minecraft:quartz_ore"
    },
    
    -- Ore-specific filters for focused mining
    ORE_FILTERS = {
        diamond = {"diamond_ore", "deepslate_diamond_ore"},
        emerald = {"emerald_ore", "deepslate_emerald_ore"},
        gold = {"gold_ore", "deepslate_gold_ore"},
        iron = {"iron_ore", "deepslate_iron_ore"},
        all = nil  -- Mine all ores
    }
}

return CONFIG