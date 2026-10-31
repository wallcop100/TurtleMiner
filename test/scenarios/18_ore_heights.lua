-- Version: 1.0.0
-- Scenario 18: 1.18 ore heights. Diamonds at -59..-64, iron at Y 16, redstone below 0.
-- FOCUS="diamond" at TARGET_Y -58: only diamond veins are followed. Then SET
-- TARGET_Y 16 + SET FOCUS iron mid-job: the new values apply (TARGET_Y is live per
-- WP-B; grid geometry frozen until RESET_JOB) without corrupting position or grid.
return {
    title = "ore heights, FOCUS and live SET",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 18, gps = true, home = { x = 0, y = 30, z = 0 },
            settings = { TARGET_Y = -58, FOCUS = "diamond", MAX_CORRIDORS = 3 } })
        local TY = -58
        -- diamond vein below the main at f=3: -59, -60(bedrock at -60 is flat: put it at r=1 instead)
        local dia = { H.setGrid(ctx, 3, 1, TY, "minecraft:deepslate_diamond_ore"),
                      H.setGrid(ctx, 3, 2, TY, "minecraft:deepslate_diamond_ore"),
                      H.setGrid(ctx, 3, 2, TY - 1, "minecraft:deepslate_diamond_ore") }
        -- redstone vein left of the main at f=2..3 (r=-1 adjacent, r=-2 behind it)
        H.setGrid(ctx, 2, -1, TY, "minecraft:deepslate_redstone_ore")
        local redDeep = H.setGrid(ctx, 2, -2, TY, "minecraft:deepslate_redstone_ore")
        -- iron at Y 16 near where corridor 1+ mains would run if TARGET_Y moves to 16
        local W = 2 * ctx.cfg.BRANCH_LENGTH + ctx.cfg.BRANCH_SPACING
        local iron = {}
        for c = 0, 2 do
            iron[#iron + 1] = H.setGrid(ctx, 3, c * W + 1, 16, "minecraft:iron_ore")
            iron[#iron + 1] = H.setGrid(ctx, 3, c * W + 2, 16, "minecraft:iron_ore")
        end
        ctx.boot()
        H.runUntil(ctx, function()
            for _, p in ipairs(dia) do if not H.wasDug(ctx, p.x, p.y, p.z) then return false end end
            return true
        end, 3600, "diamond vein mined with FOCUS=diamond")
        H.check(not H.wasDug(ctx, redDeep.x, redDeep.y, redDeep.z), "redstone vein followed although FOCUS=diamond")
        local idA = ctx.srv.cmd(ctx.t.id, "SET", { key = "TARGET_Y", value = 16 })
        local idB = ctx.srv.cmd(ctx.t.id, "SET", { key = "FOCUS", value = "iron" })
        sim.run({ maxTime = 5 })
        for _, id in ipairs({ idA, idB }) do
            local a = ctx.srv.acks[id]
            H.check(a and a[1].ok ~= false, "SET not acked ok (%s): %s", id, tostring(a and a[1].err))
        end
        H.runUntil(ctx, function()
            for _, d in ipairs(ctx.w.digLog) do if d.y == 16 and d.by == ctx.t.id and not (d.x == 0 and d.z == 0) then return true end end
            return false
        end, 6 * 3600, "mining at the new TARGET_Y 16")
        H.runUntil(ctx, function()
            return H.doneAtHome(ctx)() or (H.wasDug(ctx, iron[1].x, iron[1].y, iron[1].z))
        end, 6 * 3600, "iron at Y16 mined (or job done)")
        H.commonChecks(ctx)
        local ironDug = 0
        for _, p in ipairs(iron) do if H.wasDug(ctx, p.x, p.y, p.z) then ironDug = ironDug + 1 end end
        H.check(ironDug > 0, "no iron mined at Y16 after SET FOCUS iron / TARGET_Y 16")
        return string.format("diamond-only at -58; %d/%d iron blocks mined at Y16 after SET", ironDug, #iron)
    end,
}
