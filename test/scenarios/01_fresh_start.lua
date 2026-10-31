-- Version: 1.0.0
-- Scenario 1: fresh start (no state, no GPS), mines 2 corridors, unloads, no prompts.
return {
    title = "fresh start, 2 corridors, unload, no prompts",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 1, fuel = 5000 })
        local W = 2 * ctx.cfg.BRANCH_LENGTH + ctx.cfg.BRANCH_SPACING
        local TY = ctx.worldTargetY
        -- ores directly on the mains, so they must be dug (home faces north: f = -z, r = +x)
        ctx.w:set(0, TY, -5, "minecraft:diamond_ore")
        ctx.w:set(W, TY, -6, "minecraft:diamond_ore")
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "2 corridors then DONE at home")
        H.commonChecks(ctx)
        local dug = H.dugSet(ctx, TY)
        for c = 0, 1 do
            for f = 2, ctx.cfg.MAIN_LENGTH do
                H.check(dug[f .. ":" .. (c * W)], "corridor %d main not dug at f=%d (r=%d)", c, f, c * W)
            end
        end
        local cp = ctx.chestPos
        local dia = ctx.w:chestCount(cp.x, cp.y, cp.z, "minecraft:diamond")
        H.check(dia >= 2, "dump chest should hold the 2 diamonds, has %d", dia)
        H.check(H.invCount(ctx.t, "minecraft:diamond") == 0, "turtle still carries diamonds after unloading")
        return string.format("DONE at home after %.0fs sim, %d blocks dug", sim.now, #H.dugGrid(ctx))
    end,
}
