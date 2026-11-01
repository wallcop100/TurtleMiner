-- Version: 1.0.0
-- Scenario 39: a blind turtle (no modem ever attached, no GPS).
--  A: boot (startup -> updater -> miner) waits for nothing: the first move comes within a few
--     seconds of sim time, for a fresh install and for a reboot mid-job; nothing errors.
--  B: the turtle's own 39x13 screen shows a status block (phase, pos, fuel, job, ores) that
--     stays on screen while log lines scroll below it, never writes off screen, and the
--     keyboard still works.
return {
    title = "offline boot speed + on-screen status",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner", "startup" },
    run = function(sim, H)
        local firstOp = nil
        local function firstMoveTime(m, crash)
            local t = m.t
            local first = nil
            local start = sim.now
            firstOp = nil
            local mine = true
            sim.addHook(t, function(e)
                if not mine then return end
                if not firstOp and e.kind == "turtle" then firstOp = sim.now - start end
                if not first and e.kind == "turtle" and e.when == "after" and e.ok
                    and (e.op == "forward" or e.op == "down" or e.op == "up" or e.op == "back") then
                    first = sim.now
                end
            end)
            sim.boot(t, { "startup" }, { background = true, crashAt = crash })
            H.runUntil(m, function() return first ~= nil end, 600, "first move after boot")
            mine = false
            return first - start
        end
        -- A1: fresh install
        local m = H.minerSetup({ id = 39, modem = false, strictTerm = true })
        local t = m.t
        local fresh = firstMoveTime(m)
        H.check(fresh <= 5, "fresh offline boot took %.1f s of sim time before the first move", fresh)
        H.check(firstOp <= 0.1, "fresh offline boot waited %.1f s before touching the turtle", firstOp)
        -- A2: reboot mid-job
        H.runUntil(m, function() return t.pos.y < m.home.y - 4 end, 3600, "goes down the shaft")
        sim.kill(t)
        local again = firstMoveTime(m)
        H.check(again <= 5, "offline reboot mid-job took %.1f s of sim time before the first move", again)
        H.check(not (t.computer.errors and #t.computer.errors > 0), "printError on a blind turtle: %s",
            t.computer.errors and t.computer.errors[1] or "")
        H.check(firstOp <= 0.1, "offline reboot waited %.1f s before touching the turtle", firstOp)

        -- B: the screen
        local term = t.computer.term
        local function rows() return term._lines() end
        local function stateOf()
            local raw = t.fs:read(".tm_state")
            return raw and sim.textutils.unserialize(raw)
        end
        H.runUntil(m, function() local st = stateOf(); return st and st.phase == "TO_WORK" and t.pos.y == m.worldTargetY end,
            3600, "mining at depth")
        local r1 = rows()
        H.check(r1[1]:find("^TO_WORK") and r1[1]:find("T39", 1, true), "B: row 1 is not phase + label: '%s'", r1[1])
        H.check(r1[3]:find("^pos %-?%d+,%-?%d+,%-?%d+ f%d") and r1[3]:find("fuel"), "B: row 3 is not position/fuel: '%s'", r1[3])
        H.check(r1[4]:find("^job c%d+ b%d+[LR] s%d+  ores %d+"), "B: row 4 is not job/ores: '%s'", r1[4])
        H.check(r1[5]:find("keys", 1, true), "B: row 5 is not the separator: '%s'", r1[5])
        -- refreshed while working (every 10 s), log lines stay below the status block
        sim.run({ maxTime = 25 })
        local r2 = rows()
        H.check(r2[3] ~= r1[3], "B: position line not refreshed after 25 s: '%s'", r2[3])
        sim.queue(t.computer, sim.now, { "char", "s" })
        sim.queue(t.computer, sim.now, { "char", "?" })
        sim.run({ maxTime = 2 })
        local r3 = rows()
        H.check(r3[1]:find("^TO_WORK"), "B: status row 1 scrolled away by log output: '%s'", r3[1])
        local logged = false
        for i = 6, #r3 do if r3[i]:find("Keys: R resume", 1, true) then logged = true end end
        H.check(logged, "B: '?' key output not in the log area:\n%s", table.concat(r3, "\n"))
        H.check(#term._violations == 0, "B: %d writes off the 39x13 screen, first at %d,%d '%s'", #term._violations,
            term._violations[1] and term._violations[1].x or 0, term._violations[1] and term._violations[1].y or 0,
            term._violations[1] and term._violations[1].text or "")
        for i = 1, #r3 do H.check(#r3[i] <= 39, "B: row %d wider than 39", i) end
        -- NEEDS_HELP shows its reason in row 2
        return string.format("first op %.2f s / first move %.1f s after a fresh boot, %.1f s after a reboot; 39x13 status: '%s'",
            firstOp, fresh, again, (r3[3]:gsub("%s+$", "")))
    end,
}
