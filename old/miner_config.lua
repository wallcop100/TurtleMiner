-- Version: 1.1.1
-- Mining configuration for TurtleMiner
-- Extracted from turtle_miner_network.lua

local CONFIG = {
    MINING_PATTERN = "branch",   -- "branch", "spiral", or "vertical"
    BRANCH_LENGTH = 16,          -- Length of each branch
    BRANCH_SPACING = 3,          -- Blocks between branches
    VERTICAL_DEPTH = 64,         -- Depth for vertical mining
    AUTO_DESCEND = true,         -- Automatically descend to target Y level
    TARGET_Y_LEVEL = -59,        -- Optimal for diamonds in 1.21.1
    FUEL_THRESHOLD = 1000,       -- Return home if fuel below this
    FUEL_RESERVE_MULTIPLIER = 3, -- Reserve 3x distance for safety
    MIN_FUEL_TO_START = 500,     -- Minimum fuel to begin operations
    MAX_STUCK_ATTEMPTS = 10,     -- Max attempts to get unstuck
    CHECK_SURROUNDING = true,    -- Check blocks around while mining
    STATUS_INTERVAL = 10,        -- Send status every N seconds
    VALUABLE_ORES = {            -- Ores to mine
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
    }
}

return CONFIG

