-- Version: 1.0.0
-- Scenario 98: a whole-cluster restart keeps the GPS constellation. Every PC reboots at once
-- (server restart): the new leader waits for the others before re-measuring, so no host is
-- paused for not having reported yet, nobody is asked for coordinates, and all hosts answer
-- again with the saved positions. Then the leader alone reboots: same result.
local function pc(id, x, y, z, mon)
    local o = { id = id, pos = { x = x, y = y, z = z }, modems = { { side = "back", kind = "basic" } } }
    if mon then o.monitor = { side = "top", w = 39, h = 14 } end
    return o
end

return {
    title = "GPS survives a whole-cluster restart and a leader restart without a new set-up",
    needs = { "net" },
    run = function(sim, H)
        H.rawGps({
            { pos = { x = 40, y = 70, z = 0 } }, { pos = { x = 35, y = 80, z = 25 } },
            { pos = { x = 30, y = 60, z = -25 } }, { pos = { x = 35, y = 75, z = 10 } },
        })
        local spec = { pc(1, 0, 70, 0, true), pc(2, 20, 70, 0), pc(3, 0, 70, 15), pc(4, 5, 80, 5), pc(5, -28, 74, 12) }
        local all = {}
        for _, o in ipairs(spec) do all[#all + 1] = H.serverComputer(o) end
        sim.run({ maxTime = 80 })
        H.uiPress(all[1], "Set up")
        sim.run({ maxTime = 30 })
        H.check(all[1].T.gps.view.st == "on", "setup: %s", all[1].T.gps.view.st)
        H.rawGps({})          -- the other GPS is gone: a new set-up would need typed coordinates

        local function checkAll(what)
            for _, S in ipairs(all) do
                local V = S.T.gps.view
                H.check(V.st == "on", "%s: #%d GPS %s (%s)", what, S.c.id, V.st, tostring(V.note))
                H.check(next(V.asks or {}) == nil, "%s: #%d asked for coordinates", what, S.c.id)
                for id = 1, 5 do
                    H.check(V.hosts[id] and V.hosts[id].st == "hosting", "%s: #%d sees host %d %s", what, S.c.id, id,
                        tostring(V.hosts[id] and V.hosts[id].st))
                end
                H.check(S.T.gps.wanted(), "%s: #%d does not answer GPS pings", what, S.c.id)
            end
        end

        for _, S in ipairs(all) do S.kill() end
        sim.run({ maxTime = 5 })
        for _, S in ipairs(all) do S.boot() end
        sim.run({ maxTime = 200 })
        checkAll("cluster restart")
        for _, S in ipairs(all) do
            H.check(not S.logText():find("paused", 1, true), "#%d paused a host:\n%s", S.c.id, S.logText())
        end

        local L
        for _, S in ipairs(all) do if S.T.isLeader() then L = S end end
        H.check(L, "no leader")
        L.kill(); sim.run({ maxTime = 3 }); L.boot()
        sim.run({ maxTime = 200 })
        checkAll("leader restart")
        H.check(all[1].T.gps.view.hosts[5].x == -28, "positions changed")
        return "all 5 PCs rebooted together, then the leader alone: constellation kept, no set-up, all hosting"
    end,
}
