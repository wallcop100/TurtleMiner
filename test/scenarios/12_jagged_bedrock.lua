-- Version: 1.0.0
-- Scenario 12: jagged bedrock (top varies per column between -64 and -60), TARGET_Y
-- -58. A diamond vein that runs down into the bedrock band stops at the unbreakable
-- blocks; the run does not go NEEDS_HELP / stuck and mining continues to DONE.
return {
    title = "jagged bedrock",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 12, gps = true, home = { x = 0, y = -40, z = 0 },
            world = { jaggedBedrock = true, seed = 7 }, settings = { TARGET_Y = -58, MAX_CORRIDORS = 2 } })
        local TY = -58
        -- vein going straight down under the main at f=3: -59 ore, -60 ore, -61 bedrock bump, -62 ore (unreachable)
        local p59 = H.setGrid(ctx, 3, 0, TY - 1, "minecraft:deepslate_diamond_ore")
        local p60 = H.setGrid(ctx, 3, 0, TY - 2, "minecraft:deepslate_diamond_ore")
        H.setGrid(ctx, 3, 0, TY - 3, "minecraft:bedrock")
        local p62 = H.setGrid(ctx, 3, 0, TY - 4, "minecraft:deepslate_diamond_ore")
        -- side vein ending in bedrock next to a branch
        local s1 = H.setGrid(ctx, 4, 2, TY - 1, "minecraft:deepslate_diamond_ore")
        H.setGrid(ctx, 4, 2, TY - 2, "minecraft:bedrock")
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "run to DONE over jagged bedrock")
        H.commonChecks(ctx)
        H.notNeedsHelp(ctx)
        H.check(H.wasDug(ctx, p59.x, p59.y, p59.z) and H.wasDug(ctx, p60.x, p60.y, p60.z), "reachable diamonds above the bedrock bump not mined")
        H.check(H.wasDug(ctx, s1.x, s1.y, s1.z), "diamond above bedrock next to the branch not mined")
        H.check(not H.wasDug(ctx, p62.x, p62.y, p62.z), "dug through bedrock?!")
        local bedrockDug = 0
        for _, d in ipairs(ctx.w.digLog) do if d.name == "minecraft:bedrock" then bedrockDug = bedrockDug + 1 end end
        H.check(bedrockDug == 0, "bedrock was dug")
        return "vein stopped at bedrock, run completed"
    end,
}
