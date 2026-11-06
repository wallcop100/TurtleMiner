-- Version: 1.0.0
-- Scenario 97: restarts during update probation (user report 2026-11-06: tm_gps "rolled back,
-- reason reboot"). A server PC that runs fine for a minute and is then restarted (chunk
-- unloaded, server restart, the player) must keep the update; only a quick boot loop rolls back.
return {
    title = "probation: spaced restarts keep the update, a quick boot loop rolls back",
    needs = { "net", "tmmesh", "tmguard", "updater", "startup" },
    run = function(sim, H)
        local gh = H.github({})
        local A = H.meshComputer({ id = 10, role = "server", http = gh.fn,
            modems = { { side = "back", kind = "wired", net = "base" } } })
        sim.run({ maxTime = 30 })
        local orig = H.repo("servers/tm_views.lua")
        local function release(v)
            gh.over["servers/tm_views.lua"] = H.bump(orig, v)
            A.T().checkNow()
            local t0 = sim.now
            while H.verOf(A.c, "tm_views.lua") ~= v and sim.now - t0 < 120 do sim.run({ maxTime = 2 }) end
            H.check(H.verOf(A.c, "tm_views.lua") == v, "%s not installed", v)
            sim.run({ maxTime = 5 })
            H.check(A.c.fs:read(".tm_mesh/probation") ~= nil, "no probation after %s", v)
        end
        release("9.6.0")
        for i = 1, 4 do
            sim.run({ maxTime = 70 })
            sim.kill(A.c); A.boot()
        end
        sim.run({ maxTime = 10 })
        H.check(H.verOf(A.c, "tm_views.lua") == "9.6.0", "spaced restarts rolled back to %s", tostring(H.verOf(A.c, "tm_views.lua")))
        H.check(A.c.fs:read(".tm_mesh/rollback") == nil, "rollback file after spaced restarts")
        sim.run({ maxTime = 300 })                      -- probation over

        release("9.6.1")
        for i = 1, 4 do
            sim.run({ maxTime = 3 })
            sim.kill(A.c); A.boot()
        end
        sim.run({ maxTime = 15 })
        H.check(H.verOf(A.c, "tm_views.lua") == "9.6.0", "boot loop kept %s", tostring(H.verOf(A.c, "tm_views.lua")))
        return "4 restarts 70 s apart kept 9.6.0; 4 quick restarts rolled 9.6.1 back"
    end,
}
