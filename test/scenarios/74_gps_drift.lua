-- Version: 1.0.0
-- Scenario 74 (CG-3): drift. A 5 PC constellation (set up silently from another GPS) keeps
-- measuring itself every 10 minutes and whenever a member reboots.
--   a) a host moved 6 blocks: re-solved silently from the other four, position updated.
--   b) a host moved out of everyone's range and rebooted: PAUSED (stops answering, the GPS
--      page says why), the other four keep hosting.
--   c) it comes back and reboots: resumes.
--   d) two hosts gone: too few, GPS stops cleanly (nobody answers) and the offer returns
--      when they are back.
local function pc(id, x, y, z, mon)
    local o = { id = id, pos = { x = x, y = y, z = z }, modems = { { side = "back", kind = "basic" } } }
    if mon then o.monitor = { side = "top", w = 39, h = 14 } end
    return o
end

return {
    title = "GPS drift: moved host re-solved, lost host paused then resumed, too few stops cleanly",
    needs = { "net" },
    run = function(sim, H)
        H.rawGps({
            { pos = { x = 40, y = 70, z = 0 } }, { pos = { x = 35, y = 80, z = 25 } },
            { pos = { x = 30, y = 60, z = -25 } }, { pos = { x = 35, y = 75, z = 10 } },
        })
        local spec = { pc(1, 0, 70, 0, true), pc(2, 20, 70, 0), pc(3, 0, 70, 15), pc(4, 5, 80, 5), pc(5, -28, 74, 12) }
        local all, byId = {}, {}
        for _, o in ipairs(spec) do local S = H.serverComputer(o); all[#all + 1] = S; byId[o.id] = S end
        local A, C, D, E = byId[1], byId[3], byId[4], byId[5]
        sim.run({ maxTime = 80 })
        H.uiPress(A, "Set up")
        sim.run({ maxTime = 30 })
        local V = A.T.gps.view
        H.check(V.st == "on", "setup: %s %s", V.st, tostring(V.note))
        H.check(V.hosts[3].st == "hosting" and V.hosts[5].x == -28, "setup result wrong")

        -- a) moved 6 blocks, no reboot: the periodic re-measure fixes it silently
        H.check(A.T.gps.DRIFT_MS == 600000, "re-measure period is not 10 minutes")
        A.T.gps.DRIFT_MS = 120000          -- shortened to keep the run quick
        C.c.pos.x = C.c.pos.x + 6
        sim.run({ maxTime = 150 })
        H.check(V.hosts[3].st == "hosting" and V.hosts[3].x == 6, "moved host not re-solved: %s %s", V.hosts[3].st,
            tostring(V.hosts[3].x))
        H.check(A.logText():find("#3 moved, position updated to 6 70 15", 1, true), "no log line:\n%s", A.logText())
        H.check(V.hosts[1].x == 0 and V.hosts[2].x == 20 and V.hosts[4].x == 5, "others changed")
        H.check(C.T.gps.wanted(), "#3 stopped hosting after a silent re-solve")

        -- b) out of range + reboot: paused, others go on
        local home = { x = C.c.pos.x, y = C.c.pos.y, z = C.c.pos.z }
        C.c.pos.x = 400
        C.kill(); sim.run({ maxTime = 2 }); C.boot()
        sim.run({ maxTime = 110 })
        H.check(V.hosts[3].st == "paused" and V.hosts[3].why, "not paused: %s", tostring(V.hosts[3].st))
        H.check(not C.T.gps.wanted(), "paused PC still answers GPS pings")
        H.check(V.st == "on" and A.T.gps.wanted() and byId[2].T.gps.wanted() and D.T.gps.wanted() and E.T.gps.wanted(),
            "the others stopped (%s)", V.st)
        local ui = H.uiTerminal(A)
        ui.view = "gps"; A.T.markDirty(); sim.run({ maxTime = 1 })
        H.check(A.c.term._text():find("#3 paused", 1, true), "GPS page does not show why:\n%s", A.c.term._text())

        -- c) back and rebooted: resumes
        C.c.pos.x, C.c.pos.y, C.c.pos.z = home.x, home.y, home.z
        C.kill(); sim.run({ maxTime = 2 }); C.boot()
        sim.run({ maxTime = 40 })
        H.check(V.hosts[3].st == "hosting" and C.T.gps.wanted(), "did not resume: %s", tostring(V.hosts[3].st))

        -- d) two hosts gone: too few -> stop cleanly, then re-offer
        D.c.pos.x, E.c.pos.x = 400, 450
        D.kill(); E.kill(); sim.run({ maxTime = 2 }); D.boot(); E.boot()
        sim.run({ maxTime = 110 })
        H.check(V.st ~= "on" and next(V.hosts) == nil, "GPS still on with too few hosts: %s", V.st)
        for _, S in ipairs(all) do H.check(not S.T.gps.wanted(), "#%d still answers GPS pings", S.c.id) end
        H.check(A.logText():find("too few usable hosts", 1, true), "no log line")
        D.c.pos.x, E.c.pos.x = 5, -28
        D.kill(); E.kill(); sim.run({ maxTime = 2 }); D.boot(); E.boot()
        sim.run({ maxTime = 90 })
        H.check(V.st == "offer" and V.n == 5, "offer did not come back: %s %s", V.st, tostring(V.note))
        return "moved host re-solved silently; lost host paused (page says why) then resumed; 2 lost -> GPS stops cleanly, offer returns"
    end,
}
