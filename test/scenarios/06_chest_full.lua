-- Version: 1.0.0
-- Scenario 6: storage chest full -> NEEDS_HELP with a reason (no prompt); when the
-- chest is emptied the turtle unloads and carries on by itself.
return {
    title = "chest full",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local full, inv = {}, {}
        for s = 1, 27 do full[s] = { name = "minecraft:andesite", count = 64 } end
        for s = 1, 15 do inv[s] = { name = "minecraft:raw_iron", count = 64 } end
        local ctx = H.minerSetup({ id = 6, chest = full, inventory = inv, settings = { DROP_TRASH = false } })
        ctx.boot()
        H.runUntil(ctx, function() return ctx.phase() == "NEEDS_HELP" end, 3600, "NEEDS_HELP on full chest")
        local reason = tostring(ctx.reason())
        H.check(reason:lower():find("full"), "NEEDS_HELP reason should mention full, got %s", reason)
        sim.run({ maxTime = 120 })
        H.check(ctx.phase() == "NEEDS_HELP", "left NEEDS_HELP while chest still full: %s", tostring(ctx.phase()))
        local cp = ctx.chestPos
        ctx.w:setChestContents(cp.x, cp.y, cp.z, {})
        local t0 = sim.now
        H.runUntil(ctx, function()
            return ctx.w:chestCount(cp.x, cp.y, cp.z, "minecraft:raw_iron") >= 15 * 64 and ctx.phase() ~= "NEEDS_HELP"
        end, 600, "resume after chest emptied")
        local digs0 = #ctx.w.digLog
        H.runUntil(ctx, function() return #ctx.w.digLog > digs0 + 5 end, 600, "mining again after unload")
        H.commonChecks(ctx)
        return string.format("reason %q; resumed %.0fs after the chest was emptied", reason, sim.now - t0)
    end,
}
