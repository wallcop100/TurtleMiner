-- Version: 1.0.0
-- Scenario 89 (AR-T / AR-G): mobile GPS. With no GPS hosts at all, a turtle sitting in an
-- isolated pocket at depth pings and gets an exact fix from the replies of at least 4 working
-- army turtles. Then four hosts that lie about their position are added and a real army turtle
-- at depth reboots: it must keep its journal position (a fix that disagrees by more than 2
-- blocks is rejected). SKIPs until the army modules and miner/gpsmobile.lua exist.
return {
    title = "mobile GPS: fix from >=4 working turtles at depth; a fix that disagrees with the journal is rejected",
    needs = { "net", "mine", "miner" },
    run = function(sim, H)
        local A = require("army")(sim, H)
        A.need({ "miner/gpsmobile.lua" })
        H.rawGps({})
        local st = A.station({ y = 8, shaftTo = -2 })
        local ld, ui = A.leader(st), A.ui()
        local rec = A.newArmy(st, ld, ui, { name = "gm", ores = { "lapis" } })
        local ts = A.joinTurtles(st, ld, "gm", 6, { gps = true })
        local y0 = rec.levels[1].y
        A.runUntil(st, function()
            local n = 0
            for _, t in ipairs(ts) do if t.pos.y <= y0 + 1 then n = n + 1 end end
            return n >= 5
        end, 4000, "5 turtles at depth")
        -- an observer in a closed pocket near the shaft bottom (not in anybody's way)
        local o = st.toWorld(1, 3, y0 - 2)
        st.w:set(o.x, o.y, o.z, "air")
        local obs = sim.turtle(st.w, { id = 77, pos = o, equip = A.BASIC, gps = false })
        local oc = H.netTurtle(obs, "Observer")
        sim.run({ maxTime = 2 })
        local want = string.format("%d,%d,%d", o.x, o.y, o.z)
        local n0 = #sim.net.gpsAnswers
        local fix
        for _ = 1, 6 do
            oc.jobs[#oc.jobs + 1] = function(net, G)
                local x, y, z = G.gps.locate(2)
                return x and string.format("%d,%d,%d", x, y, z) or "none"
            end
            sim.run({ maxTime = 12 })
            fix = oc.results[#oc.results]
            if fix == want then break end
        end
        H.check(fix == want, "observer fix %s, want %s (gps answers heard: %d)", tostring(fix), want, #sim.net.gpsAnswers - n0)
        local from = {}
        for i = n0 + 1, #sim.net.gpsAnswers do from[sim.net.gpsAnswers[i].from] = true end
        local nh = 0
        for _ in pairs(from) do nh = nh + 1 end
        H.check(nh >= 4, "only %d distinct working turtles answered", nh)

        -- liars: four virtual hosts say they are 20 blocks east of where they are
        local lies = {}
        for i, d in ipairs({ { 30, 0, 0 }, { -30, 10, 5 }, { 5, 25, -30 }, { 0, -20, 40 } }) do
            local p = { x = o.x + d[1], y = o.y + d[2], z = o.z + d[3] }
            lies[i] = { pos = p, says = { x = p.x + 20, y = p.y, z = p.z }, kind = "ender" }
        end
        sim.gpsHosts = lies
        local victim
        for _, t in ipairs(ts) do if t.pos.y <= y0 + 1 and #A.held(rec, t.id) > 0 then victim = t end end
        H.check(victim, "no army turtle at depth to restart")
        local before = sim.copyPos(victim.pos)
        sim.kill(victim)
        sim.boot(victim, { "miner" }, { background = true })
        sim.run({ maxTime = 120 })
        local r = ld.rec(victim.id)
        local p = r and r.st and r.st.pos
        H.check(p, "restarted turtle sent no status")
        H.check(H.dist(p, victim.pos) <= 2 or H.dist(p, victim.prevPos) <= 2, "restarted turtle reports %s but is at %s (took a wrong fix?)",
            H.fmtPos(p), H.fmtPos(victim.pos))
        sim.gpsHosts = {}
        return string.format("observer got an exact fix from %d working turtles; with 4 lying hosts a restarted turtle (was %s) kept %s",
            nh, H.fmtPos(before), H.fmtPos(p))
    end,
}
