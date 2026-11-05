-- Version: 1.0.0
-- Scenario 13: a branch crosses a 5-wide air cave and the main crosses a ravine
-- (air from far below to above the tunnel). The turtle keeps going (no stuck, no
-- false ore), finds ore exposed on the cave wall next to its tunnel, and its
-- reported position stays exact.
return {
    title = "caves and ravines",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 13, settings = { BRANCH_LENGTH = 10, MAIN_LENGTH = 12, MAX_CORRIDORS = 1 } })
        local TY = ctx.worldTargetY
        local w = ctx.w
        -- cave: f=3..5, r=4..8, from TY-1 to TY+2 (branch R of b=0 runs along f=4)
        for f = 3, 5 do
            for r = 4, 8 do
                for y = TY - 1, TY + 2 do
                    local p = H.gridToWorld(ctx, f, r, y)
                    w:set(p.x, p.y, p.z, "air")
                end
            end
        end
        -- ore on the far cave wall, adjacent to the branch tunnel cell (f=4, r=9)
        local wallOre = H.setGrid(ctx, 3, 9, TY, "minecraft:gold_ore")
        -- ravine across the main at f=6..7: air from TY-12 to TY+6, r=-2..2
        for f = 6, 7 do
            for r = -2, 2 do
                for y = TY - 12, TY + 6 do
                    local p = H.gridToWorld(ctx, f, r, y)
                    w:set(p.x, p.y, p.z, "air")
                end
            end
        end
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "run to DONE through cave and ravine")
        H.commonChecks(ctx)
        H.notNeedsHelp(ctx)
        H.check(H.wasDug(ctx, wallOre.x, wallOre.y, wallOre.z), "ore on the cave wall next to the tunnel not mined")
        H.check(ctx.watch.statusChecked > 0, "no status messages to check position against")
        local dug = H.dugSet(ctx, TY)
        H.check(dug["4:10"], "branch did not continue past the cave (f=4, r=10 not dug)")
        H.check(dug["8:0"] or dug["9:0"], "main did not continue past the ravine")
        return string.format("%d status positions checked", ctx.watch.statusChecked)
    end,
}
