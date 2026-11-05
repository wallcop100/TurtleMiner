-- Version: 1.0.0
-- Scenario 9: server crash with world autosave lag: the world (pos, fuel, blocks,
-- inventory) rolls back N moves while the turtle's files keep the newer journal.
-- nav.recover must find the matching journal entry by fuel and land on the
-- world's real position/facing; never a silent wrong answer.
local OPS = { "f", "f", "f", "r", "f", "f", "l", "f", "f", "f", "f", "f", "f" }

return {
    title = "world rollback",
    needs = { "state", "nav" },
    run = function(sim, H)
        local function snapAtForward(t, n)
            local holder, count = {}, 0
            sim.observe(function(e)
                if e.kind == "turtle" and e.turtle == t and e.op == "forward" and e.when == "after" and e.ok then
                    count = count + 1
                    if count == n then holder.snap = sim.snapshot(t) end
                end
            end)
            return holder
        end
        local done = 0
        local cases = {
            { name = "rollback 8 moves", ops = OPS, snapAt = 4, mustRecover = true },
            { name = "rollback across a refuel", ops = { "f", "f", "f", "r", "f", "f", "l", "f", "R", "f", "f", "f" }, snapAt = 4,
              mustRecover = true, inv = { [16] = { name = "minecraft:coal", count = 4 } } },
            { name = "rollback after crash mid-move", ops = OPS, snapAt = 4, mustRecover = true,
              crash = function() return H.crashOn(H.isTurtleOp("forward", "after"), 9) end },
            { name = "rollback past the last snapshot save", ops = { "f", "f", "s", "f", "f", "f" }, snapAt = 1, mustRecover = false },
        }
        for _, gps in ipairs({ false, true }) do
            for _, case in ipairs(cases) do
                sim.reset()
                local ctx = H.navSetup({ gps = gps, inventory = case.inv })
                local label = (gps and "GPS " or "no-GPS ") .. case.name
                local holder = snapAtForward(ctx.t, case.snapAt)
                local r = ctx.drive(case.ops, { crashAt = case.crash and case.crash() })
                H.check(r.status == "exit" or r.status == "crashed", "%s: driver %s %s", label, r.status, tostring(r.err))
                H.check(holder.snap, "%s: no snapshot taken", label)
                local before = H.fmtPos(ctx.t.pos)
                sim.rollback(ctx.t, holder.snap)
                local p = ctx.probe()
                H.check(not p.noState, "%s: state lost", label)
                if p.ok then
                    local okm, wp, wf = ctx.matches(p)
                    H.check(okm, "%s: world rolled back from %s to %s facing %d, recover says %s facing %s", label,
                        before, H.fmtPos(ctx.t.pos), ctx.t.facing, H.fmtPos(wp), tostring(wf))
                else
                    H.check(not gps and not case.mustRecover, "%s: recover failed (%s) but the journal has the answer", label, tostring(p.reason))
                    H.check(p.reason and p.reason ~= "", "%s: failed without reason", label)
                end
                done = done + 1
            end
        end

        if H.need(H.ALL, "full-miner variant") then
            sim.reset()
            local ctx = H.minerSetup({ id = 9, settings = { SNAPSHOT_EVERY = 1000 } })
            local holder = snapAtForward(ctx.t, 40)
            ctx.boot({ crashAt = H.crashOn(H.isTurtleOp("forward", "after"), 60) })
            sim.run({ untilFn = function() return not ctx.t.computer.alive end, maxTime = 3600 })
            H.check(ctx.t.computer.status == "crashed", "full miner did not crash as planned (%s)", ctx.t.computer.status)
            sim.rollback(ctx.t, holder.snap)
            ctx.boot()
            H.runUntil(ctx, function()
                return H.doneAtHome(ctx)() or ctx.phase() == "NEEDS_HELP"
            end, 4 * 3600, "after rollback the miner finishes (or asks for help)")
            H.commonChecks(ctx)
            if ctx.phase() == "NEEDS_HELP" then H.note("full-miner rollback ended in NEEDS_HELP: " .. tostring(ctx.reason())) end
        end
        return done .. " rollback cases"
    end,
}
