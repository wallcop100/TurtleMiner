-- Version: 1.0.0
-- Scenario 14: lava aquifer below Y -55: the TARGET_Y -58 tunnel breaches lava source
-- blocks and a lava lake; dig on lava ("Nothing to dig here") is not stuck, the
-- turtle passes through, trash dropping still works, no NEEDS_HELP.
-- Variant: water aquifer at Y -20 across the shaft.
return {
    title = "lava and water aquifers",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 14, gps = true, home = { x = 0, y = -30, z = 0 }, 
            settings = { TARGET_Y = -58, MAX_CORRIDORS = 1, DROP_TRASH = true } })
        local TY = -58
        local w = ctx.w
        -- lava sources in the main tunnel and a lake right of it
        for f = 3, 5 do local p = H.gridToWorld(ctx, f, 0, TY); w:fluid(p.x, p.y, p.z, "minecraft:lava") end
        for f = 5, 8 do
            for r = 1, 3 do
                for y = TY - 2, TY do local p = H.gridToWorld(ctx, f, r, y); w:fluid(p.x, p.y, p.z, "minecraft:lava") end
            end
        end
        -- water aquifer across the shaft at -20..-22 (and around it)
        for x = -2, 2 do for z = -2, 2 do for y = -22, -20 do w:fluid(x, y, z, "minecraft:water") end end end
        H.fillWhenAway(ctx, "minecraft:raw_gold", 1, 25)
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "run to DONE through lava and water")
        H.commonChecks(ctx)
        H.notNeedsHelp(ctx)
        local dug = H.dugSet(ctx, TY)
        H.check(dug["7:0"] or dug["8:0"], "main tunnel did not continue past the lava")
        local trash = H.droppedAwayFromHome(ctx, function(n)
            return n == "minecraft:cobblestone" or n == "minecraft:cobbled_deepslate"
        end)
        H.check(trash > 0, "trash never dropped although the inventory was nearly full")
        return string.format("passed lava + water; %d trash items dropped", trash)
    end,
}
