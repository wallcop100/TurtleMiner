-- Version: 1.0.0
-- Scenario 40: GPS turtle whose GPS hosts are only reachable above Y 0 (wireless modems reach
-- 64 blocks, so at mining depth gps.locate times out).
--  A: crash mid-turn in a tunnel at depth -> no fix -> recovers like a blind turtle (probe +
--     known-open map), never NEEDS_HELP just because calibration needs GPS; finishes the job
--  B: failed locates are not retried at depth (no 2 s wait per trip / per recovery step)
--  C: position lost at depth with SURFACE_IF_LOST: climbs, gets a fix above Y 0, calibrates,
--     goes home on its own and finishes the job
return {
    title = "GPS out of range underground",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local function gen(_, y) if y > 0 then return "minecraft:air" end return nil end
        local function setup(settings)
            sim.reset()
            local m = H.minerSetup({ id = 40, gps = true, world = { gen = gen }, settings = settings })
            m.t.gpsMinY = 0
            return m
        end
        local function deepCrash(m, pred)
            local t = m.t
            local crash = H.crashOn(function(e)
                return pred(e) and e.pos.y == m.worldTargetY and math.abs(e.pos.x) + math.abs(e.pos.z) >= 4
            end, 3)
            m.boot({ crashAt = crash })
            sim.run({ untilFn = function() return not t.computer.alive end, maxTime = 4 * 3600 })
            H.check(crash.fired(), "did not crash at depth")
        end

        -- A + B: turn crash at depth
        local cases = 0
        for _, when in ipairs({ "before", "after" }) do
            local m = setup()
            local t = m.t
            deepCrash(m, function(e) return e.kind == "turtle" and (e.op == "turnLeft" or e.op == "turnRight") and e.when == when end)
            local locates0 = t.computer.gpsLocates or 0
            local t0 = sim.now
            local firstMove
            sim.addHook(t, function(e)
                if not firstMove and e.when == "after" and e.ok and (e.op == "forward" or e.op == "up" or e.op == "down" or e.op == "back") then
                    firstMove = sim.now
                end
            end)
            m.boot()
            H.runUntil(m, H.doneAtHome(m), 4 * 3600, "GPS turtle out of range: turn crash (" .. when .. ") then finish")
            H.commonChecks(m)
            H.check(not m.srv.phaseSeen(t.id, "NEEDS_HELP"), "A %s: NEEDS_HELP after a turn crash out of GPS range: %s",
                when, tostring((m.srv.phaseSeen(t.id, "NEEDS_HELP") or {}).reason))
            H.check(firstMove and firstMove - t0 <= 6, "B %s: %.1f s from reboot to the first move", when, (firstMove or 999) - t0)
            local locates = (t.computer.gpsLocates or 0) - locates0
            H.check(locates <= 12, "B %s: %d gps.locate calls for the rest of the job", when, locates)
            cases = cases + 1
        end

        -- C: lost at depth, SURFACE_IF_LOST
        local m = setup({ SURFACE_IF_LOST = true })
        local t = m.t
        deepCrash(m, function(e) return e.kind == "turtle" and e.op == "forward" and e.when == "before" end)
        t.fuel = 19999
        m.boot()
        H.runUntil(m, function() return m.srv.phaseSeen(t.id, "RETURNING") ~= nil end, 600, "C: surfaces and returns")
        H.runUntil(m, H.doneAtHome(m), 4 * 3600, "C: home after surfacing, job finished")
        H.check(not m.srv.phaseSeen(t.id, "ERROR"), "C: ERROR")
        m.watch.assertClean()
        return string.format("%d turn crashes at depth recovered without GPS; lost turtle surfaced into GPS range and went home", cases)
    end,
}
