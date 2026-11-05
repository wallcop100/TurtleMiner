-- Version: 1.0.0
-- Scenario 22 (review #4): crash between turtle.refuel and the journal "R" line. The world's
-- fuel is above the last journal point and nothing matches it; a refuel never moves the
-- turtle, so recover must keep the replayed position instead of "position unknown".
return {
    title = "refuel crash keeps position",
    needs = { "state", "nav" },
    run = function(sim, H)
        for _, gps in ipairs({ false, true }) do
            sim.reset()
            local label = gps and "GPS" or "no-GPS"
            local ctx = H.navSetup({ gps = gps, fuel = 100,
                inventory = { [16] = { name = "minecraft:coal", count = 4 } } })
            local r = ctx.drive({ "f", "f", "r", "f", "R", "f" },
                { crashAt = H.crashOn(H.isTurtleOp("refuel", "after"), 1) })
            H.check(r.status == "crashed", "%s: driver should have crashed, got %s %s", label, r.status,
                tostring(r.err or ""):sub(1, 300))
            local p = ctx.probe()
            H.check(p.ok, "%s: recover failed after a refuel crash: %s", label, tostring(p.reason))
            local okm, wp, wf = ctx.matches(p)
            H.check(okm, "%s: recovered to %s facing %s but turtle is at %s facing %d", label,
                H.fmtPos(wp), tostring(wf), H.fmtPos(ctx.t.pos), ctx.t.facing)
        end

        -- full miner: the refuel at home crashes, reboot must carry on (no "position unknown")
        if H.need(H.ALL, "full-miner variant") then
            sim.reset()
            local ctx = H.minerSetup({ id = 22, fuel = 300, inventory = { { name = "minecraft:coal", count = 20 } },
                settings = { FUEL_KEEP = 4, FUEL_TARGET = 2000 } })
            ctx.boot({ crashAt = H.crashOn(H.isTurtleOp("refuel", "after"), 1) })
            sim.run({ untilFn = function() return not ctx.t.computer.alive end, maxTime = 3600 })
            H.check(ctx.t.computer.status == "crashed", "full miner did not crash at refuel: %s",
                tostring(ctx.t.computer.status))
            ctx.boot()
            sim.run({ maxTime = 600, untilFn = function()
                local ph = ctx.phase(); return ph == "NEEDS_HELP" or ph == "MINING" or ph == "DONE"
            end })
            H.check(ctx.phase() ~= "NEEDS_HELP", "full miner after refuel crash: phase %s (%s)",
                tostring(ctx.phase()), tostring(ctx.reason()))
        end
        return "refuel crash: replayed position kept (no-GPS, GPS)"
    end,
}
