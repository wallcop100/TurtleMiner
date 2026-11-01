-- Version: 1.0.0
-- Scenario 35: no modem, no server. The miner must still finish its job, and the
-- keyboard controls (P pause, R resume, B return home) must work locally.
return {
    title = "offline turtle (no modem) + keyboard controls",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local m = H.minerSetup({ id = 60, modem = false, settings = { MAX_CORRIDORS = 3 } })
        local t = m.t
        local function phase()
            local raw = t.fs:read(".tm_state")
            local st = raw and sim.textutils.unserialize(raw)
            return st and st.phase
        end
        local function key(ch) sim.queue(t.computer, sim.now, { "char", ch }) end
        m.boot()
        H.runUntil(m, function() return phase() == "TO_WORK" and t.pos.y < m.home.y - 3 end, 3600, "starts working with no modem")
        H.check(next(m.srv.status) == nil, "a server heard from a turtle that has no modem")
        key("p")
        H.runUntil(m, function() return phase() == "PAUSED" end, 600, "P pauses")
        local pos = { x = t.pos.x, y = t.pos.y, z = t.pos.z }
        sim.run({ maxTime = 120 })
        H.check(H.samePos(t.pos, pos), "turtle moved while paused")
        key("r")
        H.runUntil(m, function() return phase() ~= "PAUSED" end, 600, "R resumes")
        key("b")
        H.runUntil(m, function()
            local p = phase()
            return (p == "IDLE") and m.atHome()
        end, 3600, "B returns home and idles")
        key("r")
        H.runUntil(m, function() return phase() == "DONE" and m.atHome() end, 4 * 3600, "R from IDLE finishes the job")
        return "offline run finished; P/R/B keys work"
    end,
}
