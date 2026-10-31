-- Version: 1.0.0
-- Scenario 33:
--  A (review #15): "stuck" NEEDS_HELP retries by itself; a mob that leaves lets the job finish.
--  B (review #15): a mob that never leaves: at most 5 retries, then it stays NEEDS_HELP.
--  C (review #17): PAUSED mid-tunnel, chunk unload/reboot: still PAUSED in the same spot; RESUME works.
--  D (review #21): SET HOME_Y on a no-GPS turtle is refused away from home; at home it is
--     applied and the journal history (old frame) is dropped.
return {
    title = "stuck retry, PAUSED after reboot, SET HOME_Y only at home",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        -- A ---------------------------------------------------------------
        local m = H.minerSetup({ id = 50, settings = { MAX_CORRIDORS = 1 } })
        local mp = H.gridToWorld(m, 4, 0, m.worldTargetY)
        m.w:mob(mp.x, mp.y, mp.z, math.huge)
        m.boot()
        H.runUntil(m, function() return m.phase() == "NEEDS_HELP" end, 3600, "A: NEEDS_HELP for the mob")
        H.check(tostring(m.reason()):find("retry 1/5", 1, true), "A: reason does not announce a retry: %s", tostring(m.reason()))
        m.w:mob(mp.x, mp.y, mp.z, math.huge, sim.now + 30)      -- the mob wanders off
        H.runUntil(m, H.doneAtHome(m, 10), 3600, "A: job finished after the automatic retry")
        H.commonChecks(m)

        -- B ---------------------------------------------------------------
        sim.reset()
        m = H.minerSetup({ id = 51, settings = { MAX_CORRIDORS = 1 } })
        mp = H.gridToWorld(m, 4, 0, m.worldTargetY)
        m.w:mob(mp.x, mp.y, mp.z, math.huge)
        m.boot()
        H.runUntil(m, function()
            return m.phase() == "NEEDS_HELP" and tostring(m.reason()):find("gave up", 1, true)
        end, 4 * 3600, "B: gives up after the retries")
        local helps = 0
        for _, p in ipairs(m.srv.phases[51] or {}) do if p.phase == "NEEDS_HELP" then helps = helps + 1 end end
        H.check(helps == 6, "B: %d NEEDS_HELP episodes, expected 1 + 5 retries", helps)
        H.assertSettles(m, 900, 60)
        H.commonChecks(m)

        -- C ---------------------------------------------------------------
        sim.reset()
        m = H.minerSetup({ id = 52, settings = { MAX_CORRIDORS = 2 } })
        m.boot()
        H.runUntil(m, function() return #H.dugGrid(m) > 20 end, 3600, "C: mining")
        m.srv.cmd(52, "PAUSE")
        H.runUntil(m, function() return m.phase() == "PAUSED" end, 120, "C: PAUSED")
        sim.run({ maxTime = 5 })
        local at = sim.copyPos(m.t.pos)
        H.check(H.dist(at, m.home) > 3, "C: paused at home, not mid-tunnel")
        sim.kill(m.t)
        local hellos = #m.srv.hellos
        m.boot()
        H.runUntil(m, function() return #m.srv.hellos > hellos end, 120, "C: rebooted")
        sim.run({ maxTime = 120 })
        H.check(m.phase() == "PAUSED", "C: phase %s after reboot, expected PAUSED", tostring(m.phase()))
        H.check(H.samePos(m.t.pos, at), "C: moved from %s to %s while PAUSED", H.fmtPos(at), H.fmtPos(m.t.pos))
        m.srv.cmd(52, "RESUME")
        H.runUntil(m, H.doneAtHome(m, 30), 3600, "C: finishes after RESUME")
        H.commonChecks(m)

        -- D ---------------------------------------------------------------
        sim.reset()
        m = H.minerSetup({ id = 53, settings = { MAX_CORRIDORS = 2 } })
        m.boot()
        H.runUntil(m, function() return H.dist(m.t.pos, m.home) > 5 end, 3600, "D: away from home")
        local id = m.srv.cmd(53, "SET", { key = "HOME_Y", value = 70 })
        sim.run({ maxTime = 5 })
        local a = m.srv.acks[id] and m.srv.acks[id][1]
        H.check(a and a.ok == false, "D: SET HOME_Y away from home was not refused (ack %s)", tostring(a and a.ok))
        m.srv.cmd(53, "RETURN_HOME")
        H.runUntil(m, function() return m.phase() == "IDLE" and m.atHome() end, 1200, "D: home")
        m.watch.assertClean()
        id = m.srv.cmd(53, "SET", { key = "HOME_Y", value = 70 })
        sim.run({ maxTime = 5 })
        a = m.srv.acks[id] and m.srv.acks[id][1]
        H.check(a and a.ok == true, "D: SET HOME_Y at home refused: %s", tostring(a and a.err))
        m.srv.cmd(53, "REQUEST_STATUS")
        sim.run({ maxTime = 5 })
        local s = m.srv.status[53]
        H.check(s.home.y == 70 and s.pos.y == 70, "D: home/pos y %s/%s after SET HOME_Y 70", tostring(s.home.y), tostring(s.pos.y))
        local j = m.t.fs:read(".tm_journal") or ""
        for line in j:gmatch("[^\n]+") do
            local tag, y = line:match("^(%a)%s+%-?%d+%s+(%-?%d+)")
            if tag == "D" or tag == "S" then
                H.check(tonumber(y) == 70, "D: journal still has a line in the old frame: %s", line)
            end
        end
        H.check(m.srv.homes[53] and m.srv.homes[53].home.y == 70, "D: server home record not updated")
        return "stuck retry ok; gave up after 5; PAUSED kept over reboot; HOME_Y refused away, applied at home"
    end,
}
