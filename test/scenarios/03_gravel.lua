-- Version: 1.0.0
-- Scenario 3: a 20-high gravel column (and sand) in the path is not treated as stuck.
return {
    title = "gravel column",
    needs = { "state", "nav" },
    run = function(sim, H)
        for _, case in ipairs({
            { op = "f", what = "gravel in front", world = function(w) w:gravelColumn(0, 0, -1, 20) end, expect = { x = 0, y = 0, z = -1 } },
            { op = "u", what = "gravel above", world = function(w) w:gravelColumn(0, 1, 0, 20) end, expect = { x = 0, y = 1, z = 0 } },
            { op = "f", what = "sand in front", world = function(w) w:gravelColumn(0, 0, -1, 20, "minecraft:sand") end, expect = { x = 0, y = 0, z = -1 } },
        }) do
            sim.reset()
            local ctx = H.navSetup({ world = case.world })
            local r = ctx.drive({ case.op })
            H.check(r.status == "exit", "%s: driver %s %s", case.what, r.status, tostring(r.err or r.why))
            local res = r.ret[1].results[1]
            H.check(res.ok, "%s: nav returned %s (%s) - treated as stuck", case.what, tostring(res.ok), tostring(res.why))
            H.check(H.samePos(ctx.t.pos, case.expect), "%s: turtle at %s, expected %s", case.what, H.fmtPos(ctx.t.pos), H.fmtPos(case.expect))
            H.check(ctx.t.digs >= 20, "%s: only %d digs for a 20-high column", case.what, ctx.t.digs)
        end
        if H.need(H.ALL, "full-miner variant") then
            sim.reset()
            local ctx = H.minerSetup({ id = 3 })
            local TY = ctx.worldTargetY
            ctx.w:gravelColumn(0, TY, -4, 20)
            ctx.w:gravelColumn(0, TY, -7, 20)
            ctx.w:gravelColumn(2, TY, -4, 20)
            ctx.boot()
            H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "full run through gravel")
            local nh = ctx.srv.phaseSeen(ctx.t.id, "NEEDS_HELP")
            H.check(not nh, "miner asked for help in gravel: %s", tostring(nh and nh.reason))
            H.commonChecks(ctx)
        end
    end,
}
