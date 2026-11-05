-- Version: 1.0.0
-- Scenario 57 (MU-1): a file edited by hand (with its `-- Version:` bumped) on a wired-only
-- PC spreads to every device that holds it.
--   #10 server PC (wired + ender, /files/), #11 wired-only server PC (/files/), #30 pocket,
--   turtle #1 mining. On #11 someone edits tm_ui.lua (computers) and files/mine.lua (turtles)
--   and bumps both to 9.2.0; a second edit without a bump (tm_db.lua) is not released.
--   Within the 10-minute check #11 signs both; #10 and the pocket install tm_ui.lua 9.2.0, #10
--   keeps files/mine.lua 9.2.0 for the turtles and the turtle installs mine.lua at home.
return {
    title = "manual edit + version bump on a wired-only PC spreads",
    needs = { "net", "miner", "tmmesh", "tmguard", "updater", "startup" },
    run = function(sim, H)
        local wired = { side = "back", kind = "wired", net = "base" }
        local A = H.meshComputer({ id = 10, role = "server", modems = { wired, { side = "top", kind = "ender" } } })
        local B = H.meshComputer({ id = 11, role = "server", modems = { wired } })
        local P = H.meshComputer({ id = 30, role = "pocket", modems = { { side = "back", kind = "ender" } } })
        local ctx = H.minerSetup({ id = 1, settings = { AUTO_UPDATE = true, MAX_CORRIDORS = 6, MAIN_LENGTH = 16 } })
        sim.boot(ctx.t, { "startup" }, { background = true })
        sim.run({ maxTime = 60 })
        local tc = ctx.t.computer
        -- the edit
        local t0 = sim.now
        B.c.fs:write("tm_ui.lua", H.bump(H.repo("servers/tm_ui.lua"), "9.2.0", "-- edited by hand on #11"))
        B.c.fs:write("files/mine.lua", H.bump(H.repo("miner/mine.lua"), "9.2.0", "-- edited by hand on #11"))
        B.c.fs:write("tm_db.lua", H.repo("servers/tm_db.lua") .. "\n-- edited, no version bump\n")
        local doneAt = {}
        local function check()
            if not doneAt.A and H.verOf(A.c, "tm_ui.lua") == "9.2.0" and H.verOf(A.c, "files/mine.lua") == "9.2.0" then doneAt.A = sim.now - t0 end
            if not doneAt.P and H.verOf(P.c, "tm_ui.lua") == "9.2.0" then doneAt.P = sim.now - t0 end
            if not doneAt.T and H.verOf(tc, "mine.lua") == "9.2.0" then doneAt.T = sim.now - t0 end
            return doneAt.A and doneAt.P and doneAt.T
        end
        sim.run({ untilFn = check, maxTime = 2400 })
        local EB = B.T().mesh
        local rel = EB.held("servers/tm_ui.lua")
        H.check(rel and rel.version == "9.2.0" and rel.origin == 11 and rel.sig, "#11 did not sign its edit")
        local relA = A.T().mesh.held("miner/mine.lua")
        H.check(relA and relA.version == "9.2.0" and relA.origin == 11, "#10 does not hold #11's mine.lua release")
        local log = table.concat(B.T().S.log, "\n")
        H.check(doneAt.A and doneAt.P and doneAt.T, "not everywhere: #10 %s/%s, pocket %s, turtle %s",
            tostring(H.verOf(A.c, "tm_ui.lua")), tostring(H.verOf(A.c, "files/mine.lua")), tostring(H.verOf(P.c, "tm_ui.lua")),
            tostring(H.verOf(tc, "mine.lua")))
        H.check(A.c.fs:read("tm_ui.lua") == B.c.fs:read("tm_ui.lua"), "#10 got different content")
        -- the edit without a version bump stays local, with one warning
        H.check(A.c.fs:read("tm_db.lua") == H.repo("servers/tm_db.lua"), "unbumped tm_db.lua edit spread")
        H.check(B.c.fs:read("tm_db.lua") ~= H.repo("servers/tm_db.lua"), "#11's unbumped edit was overwritten")
        local warned = 0
        for k in pairs(EB.warnedKeys()) do if k:find("^e|servers/tm_db.lua") then warned = warned + 1 end end
        H.check(warned == 1, "unbumped edit warned %d times on #11", warned)
        sim.run({ maxTime = 60 })
        for _, c in ipairs({ A.c, B.c, P.c, tc }) do H.check(c.alive, "#%d stopped: %s", c.id, tostring(c.err)) end
        H.commonChecks(ctx)
        return string.format("edit on wired-only #11 released at its 10-min check; #10 after %.0f s, pocket %.0f s, turtle %.0f s; unbumped edit kept local (1 warning)",
            doneAt.A, doneAt.P, doneAt.T)
    end,
}
