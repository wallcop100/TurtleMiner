-- Version: 1.2.0
-- TurtleMiner configuration. Do not edit values here; use `install` or
-- `set tminer.<KEY> <value>` on the turtle, or the SET command from the monitor.

local config = {}

config.DEFAULTS = {
    -- Grid
    TARGET_Y        = -58,   -- mining level (just above bedrock in 1.18+), world Y
    HOME_Y          = -9999, -- world Y of the home spot; only needed without GPS (-9999 = not set)
    BRANCH_LENGTH   = 32,    -- blocks per branch, each side
    BRANCH_SPACING  = 3,     -- distance between branch centres (3 = 2 solid blocks between, full coverage)
    MAIN_LENGTH     = 64,    -- length of each corridor's main tunnel
    MAX_CORRIDORS   = 8,     -- stop with DONE after this many corridors

    -- Ores
    FOCUS           = "all", -- "all" or an ore family e.g. "diamond", "iron", "ancient_debris"
    VEIN_MINING     = true,
    VEIN_MAX        = 64,    -- max blocks per vein
    ORES = {
        "coal_ore", "iron_ore", "copper_ore", "gold_ore", "redstone_ore",
        "lapis_ore", "diamond_ore", "emerald_ore", "nether_gold_ore",
        "nether_quartz_ore", "ancient_debris",
        "raw_iron_block", "raw_copper_block", "raw_gold_block", -- 1.18 large ore veins
    },                       -- matched against block name with "deepslate_" stripped, any mod namespace;
                             -- family = name without "_ore" (raw_X_block -> X), e.g. "iron"
    TRASH = {
        "minecraft:cobblestone", "minecraft:cobbled_deepslate", "minecraft:dirt",
        "minecraft:gravel", "minecraft:tuff", "minecraft:granite", "minecraft:diorite",
        "minecraft:andesite", "minecraft:netherrack", "minecraft:calcite",
        "minecraft:smooth_basalt", "minecraft:amethyst_block", "minecraft:amethyst_shard",
        "minecraft:pointed_dripstone", "minecraft:dripstone_block", "minecraft:sand",
        "minecraft:flint", "minecraft:moss_block", "minecraft:basalt", "minecraft:blackstone",
    },
    DROP_TRASH      = true,  -- drop TRASH items in the tunnel when inventory is nearly full

    -- Fuel
    FUEL_MARGIN     = 200,   -- spare fuel kept on top of distance-to-home
    FUEL_KEEP       = 16,    -- fuel items kept in reserve, never dumped
    FUEL_TARGET     = 5000,  -- refuel up to this at home if a fuel chest is present
    BURN_COAL       = true,  -- burn mined coal when fuel is below FUEL_TARGET

    -- Network / timing
    STATUS_INTERVAL = 10,    -- seconds between status messages
    SNAPSHOT_EVERY  = 100,   -- moves between full state snapshots (journal covers the rest)
    STUCK_TIMEOUT   = 60,    -- seconds without progress before a move gives up
    HELP_RETRY      = 30,    -- seconds between automatic retries while NEEDS_HELP
    AUTO_UPDATE     = true,  -- check for updates at boot when at home

    -- Recovery
    SURFACE_IF_LOST = false, -- position lost after a crash: dig straight up (never protected
                             -- blocks) until 8 open cells in a row, unbreakable block, or fuel 50;
                             -- then NEEDS_HELP "lost: surfaced here". GPS turtles retry GPS every
                             -- 16 blocks on the way up and go home on a fix.
}

-- Keys the monitor may change with SET, with validators.
local function isInt(lo, hi)
    return function(v)
        return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
    end
end
local function isBool(v) return type(v) == "boolean" end
local function isStr(v) return type(v) == "string" and #v > 0 and #v <= 32 end

config.REMOTE_KEYS = {
    TARGET_Y       = isInt(-64, 320),
    HOME_Y         = isInt(-64, 320),
    BRANCH_LENGTH  = isInt(4, 128),
    BRANCH_SPACING = isInt(2, 8),
    MAIN_LENGTH    = isInt(8, 256),
    MAX_CORRIDORS  = isInt(1, 64),
    FOCUS          = isStr,
    VEIN_MINING    = isBool,
    VEIN_MAX       = isInt(1, 512),
    DROP_TRASH     = isBool,
    FUEL_MARGIN    = isInt(0, 10000),
    FUEL_KEEP      = isInt(0, 64),
    FUEL_TARGET    = isInt(0, 100000),
    BURN_COAL      = isBool,
    STATUS_INTERVAL= isInt(2, 120),
    AUTO_UPDATE    = isBool,
    SURFACE_IF_LOST= isBool,
}

local PREFIX = "tminer."

function config.load()
    if settings and settings.load then pcall(settings.load) end
    local cfg = {}
    for k, v in pairs(config.DEFAULTS) do
        local s = settings and settings.get(PREFIX .. k)
        if s ~= nil and type(s) == type(v) then cfg[k] = s else cfg[k] = v end
    end
    return cfg
end

function config.set(key, value)
    local check = config.REMOTE_KEYS[key]
    if not check then return false, "unknown or read-only key: " .. tostring(key) end
    if not check(value) then return false, "invalid value for " .. key end
    settings.set(PREFIX .. key, value)
    if settings.save then settings.save() end
    return true
end

return config
