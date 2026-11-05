-- Version: 1.0.0
-- Scenario 4: bedrock / unbreakable -> nav gives up with "unbreakable" quickly
-- (no infinite loop); the full miner goes NEEDS_HELP with a reason and settles.
return {
    title = "bedrock",
    needs = { "state", "nav" },
    run = function(sim, H)
        for _, case in ipairs({
            { op = "f", what = "bedrock in front", world = function(w) w:set(0, 0, -1, "minecraft:bedrock") end },
            { op = "d", what = "bedrock floor", pos = { x = 0, y = -59, z = 0 } },
            { op = "u", what = "bedrock above", world = function(w) w:set(0, 1, 0, "minecraft:bedrock") end },
        }) do
            sim.reset()
            local ctx = H.navSetup({ world = case.world, pos = case.pos })
            local fuel0, t0 = ctx.t.fuel, sim.now
            local r = ctx.drive({ case.op }, { maxTime = 300 })
            H.check(r.status == "exit", "%s: driver did not return (%s %s) - infinite loop?", case.what, r.status, tostring(r.err or r.why))
            local res = r.ret[1].results[1]
            H.check(res.ok == false, "%s: nav reported success into bedrock", case.what)
            H.check(tostring(res.why):find("unbreakable"), "%s: reason should be 'unbreakable', got %s", case.what, tostring(res.why))
            H.check(ctx.t.ops < 50, "%s: %d turtle ops before giving up", case.what, ctx.t.ops)
            H.check(sim.now - t0 < 60, "%s: took %.0fs (should not wait for the stuck timeout)", case.what, sim.now - t0)
            H.check(ctx.t.fuel == fuel0, "%s: fuel changed", case.what)
        end
        if H.need(H.ALL, "full-miner variant") then
            sim.reset()
            local ctx = H.minerSetup({ id = 4 })
            ctx.w:fill(-12, -3, -12, 12, -3, 12, "minecraft:bedrock")
            ctx.boot()
            H.runUntil(ctx, function() return ctx.phase() == "NEEDS_HELP" end, 3600, "NEEDS_HELP on bedrock")
            local reason = ctx.reason()
            H.check(reason and reason ~= "", "NEEDS_HELP without a reason")
            H.assertSettles(ctx, 600)
            H.commonChecks(ctx)
            return "NEEDS_HELP reason: " .. reason
        end
    end,
}
