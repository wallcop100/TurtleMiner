-- Version: 1.0.0
-- Scenario 23 (review #5): unlimited fuel, no GPS, crash with a move in flight. Fuel cannot
-- tell whether the move happened; the block stored in the intent (destination for f/u/d,
-- front for b) is compared with what is there now. A proven change settles it; anything
-- ambiguous must be NEEDS_HELP, never a wrong position.
return {
    title = "unlimited fuel move crash",
    needs = { "state", "nav" },
    run = function(sim, H)
        local settled, helped = 0, 0
        local cases = {
            -- re-enter a dug cell, stone beyond it
            { name = "forward into tunnel end, after", ops = { "f", "f", "b", "f" }, op = "forward", n = 3, when = "after", must = true },
            { name = "forward into tunnel end, before", ops = { "f", "f", "b", "f" }, op = "forward", n = 3, when = "before" },
            -- digging forward through stone
            { name = "dig forward, after", ops = { "f", "f" }, op = "forward", n = 2, when = "after", must = true },
            { name = "dig forward, before", ops = { "f", "f" }, op = "forward", n = 2, when = "before" },
            { name = "dig down, after", ops = { "d", "d" }, op = "down", n = 2, when = "after", must = true },
            { name = "dig up, after", ops = { "u", "u" }, op = "up", n = 2, when = "after", must = true },
            -- back out of a dead end: front stone -> air (the cell it left)
            { name = "back, after", ops = { "f", "b" }, op = "back", n = 1, when = "after", must = true },
            { name = "back, before", ops = { "f", "b" }, op = "back", n = 1, when = "before" },
            -- walking along an open tunnel: air -> air is ambiguous
            { name = "open tunnel, after", ops = { "f", "f", "f", "b", "b", "f" }, op = "forward", n = 4, when = "after" },
        }
        for _, c in ipairs(cases) do
            sim.reset()
            local ctx = H.navSetup({ fuel = "unlimited" })
            local r = ctx.drive(c.ops, { crashAt = H.crashOn(H.isTurtleOp(c.op, c.when), c.n) })
            H.check(r.status == "crashed", "%s: driver should have crashed, got %s %s", c.name, r.status,
                tostring(r.err or ""):sub(1, 300))
            local p = ctx.probe()
            if p.ok then
                local okm, wp, wf = ctx.matches(p)
                H.check(okm, "%s: recovered to %s facing %s but turtle is at %s facing %d", c.name,
                    H.fmtPos(wp), tostring(wf), H.fmtPos(ctx.t.pos), ctx.t.facing)
                settled = settled + 1
            else
                H.check(not c.must, "%s: must be settled by inspect, got %s", c.name, tostring(p.reason))
                H.check(tostring(p.reason):find("position"), "%s: unexpected reason %s", c.name, tostring(p.reason))
                helped = helped + 1
            end
        end
        return string.format("%d settled by inspect, %d ambiguous -> NEEDS_HELP, none wrong", settled, helped)
    end,
}
