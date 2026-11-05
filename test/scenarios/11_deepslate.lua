-- Version: 1.0.0
-- Scenario 11 (1.18 worldgen): shaft from Y 20 to -58 crosses the stone -> deepslate
-- band (mixed at Y 0..8). A vein made of iron_ore + deepslate_iron_ore touching is
-- mined as one vein; cobbled_deepslate is trash and gets dropped when nearly full.
local ALL = { "config", "state", "nav", "inv", "mine", "net", "miner" }
return {
    title = "deepslate transition",
    needs = ALL,
    run = function(sim, H)
        local defaults = H.configDefaults()
        H.check(H.inList(defaults.TRASH, "minecraft:cobbled_deepslate"), "cobbled_deepslate is not in config TRASH")
        local function gen(x, y, z)
            if y < 0 then return "minecraft:deepslate" end
            if y <= 8 then return ((x * 7 + y * 3 + z * 5) % 3 == 0) and "minecraft:stone" or "minecraft:deepslate" end
            return nil
        end
        local ctx = H.minerSetup({ id = 11, gps = true, home = { x = 0, y = 20, z = 0 }, world = { gen = gen },
            settings = { TARGET_Y = -58, MAX_CORRIDORS = 1, DROP_TRASH = true } })
        local TY = -58
        -- one vein, two block variants, off to the right of the main at f=2..3
        local vein = {
            H.setGrid(ctx, 2, 1, TY, "minecraft:iron_ore"),
            H.setGrid(ctx, 2, 2, TY, "minecraft:deepslate_iron_ore"),
            H.setGrid(ctx, 3, 2, TY, "minecraft:iron_ore"),
            H.setGrid(ctx, 3, 3, TY, "minecraft:deepslate_iron_ore"),
        }
        H.fillWhenAway(ctx, "minecraft:raw_gold", 3, 40)
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "deepslate run to DONE")
        H.commonChecks(ctx)
        H.notNeedsHelp(ctx)
        for i, p in ipairs(vein) do
            H.check(H.wasDug(ctx, p.x, p.y, p.z), "vein block %d at %s not mined - variants not treated as one vein?",
                i, H.fmtPos(p))
        end
        local shaftCells = 0
        for _, d in ipairs(ctx.w.digLog) do if d.x == 0 and d.z == 0 and d.y <= 8 and d.y >= 0 then shaftCells = shaftCells + 1 end end
        H.check(shaftCells >= 8, "shaft did not cross the mixed band (%d cells)", shaftCells)
        local dropped = H.droppedAwayFromHome(ctx, function(n) return n == "minecraft:cobbled_deepslate" end)
        H.check(dropped > 0, "cobbled_deepslate never dropped as trash although the inventory was nearly full")
        H.check(H.droppedAwayFromHome(ctx, function(n) return n:find("raw_") end) == 0, "raw ore dropped as trash")
        return string.format("vein of 4 mixed blocks mined; %d cobbled_deepslate dropped as trash", dropped)
    end,
}
