-- Version: 1.0.0
-- Scenario 58 (MU-1): a file that fails load() or its hash never installs anywhere.
--   #10 server PC (/files/, HTTP), #30 pocket, turtles #1 #2 (net.lua + mesh, no mining).
--   A: GitHub has inv.lua and tm_views.lua 9.3.0 that don't compile: #10 refuses to sign them.
--   B: a hand edit on #10 (files/nav.lua 9.3.0) with a syntax error: not released (one warning).
--   C: a network member (#40) offers mine.lua 9.3.0 with a valid release note, but the file
--      doesn't compile: every device refuses it (and stops asking for it).
--   D: #40 offers state.lua 9.3.0 whose content changes on the way (hash mismatch): refused.
return {
    title = "files failing load() or hash never install",
    needs = { "net", "tmmesh", "tmguard" },
    run = function(sim, H)
        local BAD = "-- Version: 9.3.0\nlocal x = = 1\n"
        local gh = H.github({})
        local A = H.meshComputer({ id = 10, role = "server", http = gh.fn, modems = { { side = "top", kind = "ender" } } })
        local P = H.meshComputer({ id = 30, role = "pocket", modems = { { side = "back", kind = "ender" } } })
        local w = sim.world()
        local tcs = {}
        for i = 1, 2 do
            local t = sim.turtle(w, { id = i, pos = { x = i * 3, y = 0, z = 0 } })
            tcs[i] = H.netTurtle(t)
        end
        sim.run({ maxTime = 30 })
        -- A: broken files on GitHub
        gh.over["miner/inv.lua"] = BAD
        gh.over["servers/tm_views.lua"] = BAD
        A.T().checkNow()
        sim.run({ maxTime = 20 })
        -- B: broken hand edit
        A.c.fs:write("files/nav.lua", "-- Version: 9.3.0\nfunction (\n")
        A.T().mesh.scan()
        -- C + D: a network member with a broken file and a tampered transfer
        local good = H.bump(H.repo("miner/state.lua"), "9.3.0")
        local peer = H.fakePeer({ id = 40, files = { ["miner/mine.lua"] = BAD, ["miner/state.lua"] = good },
            tamper = function(name, text) if name == "miner/state.lua" then return text:gsub("local", "LOCAL", 1) end return text end })
        sim.run({ maxTime = 600 })
        local log = table.concat(A.T().S.log, "\n")
        H.check(log:find("inv.lua v9.3.0 does not compile", 1, true), "#10 did not refuse the broken GitHub file:\n%s", log:sub(-1200))
        H.check(log:find("nav.lua 9.3.0 does not compile, not released", 1, true), "#10 did not refuse the broken edit:\n%s", log:sub(-1200))
        local devs = { A.c, P.c, tcs[1], tcs[2] }
        for _, c in ipairs(devs) do
            local E = H.engineOf(c)
            H.check(E, "#%d has no mesh engine", c.id)
            for _, name in ipairs({ "miner/inv.lua", "servers/tm_views.lua", "miner/nav.lua", "miner/mine.lua", "miner/state.lua" }) do
                local h = E.holds(name) and E.held(name)
                if h and h.version == "9.3.0" then
                    -- only #10's own broken edit, kept locally and never served (no signature)
                    H.check(c.id == 10 and name == "miner/nav.lua" and h.sig == nil, "#%d holds %s 9.3.0", c.id, name)
                end
            end
            for _, f in ipairs({ "inv.lua", "tm_views.lua", "mine.lua", "state.lua", "files/inv.lua", "files/mine.lua", "files/state.lua" }) do
                H.check(H.verOf(c, f) ~= "9.3.0", "#%d installed %s 9.3.0", c.id, f)
            end
        end
        -- refused, then left alone: a bounded number of requests
        H.check(peer.chunks > 0 and peer.chunks <= 4 * 3 * 3, "#40 got %d chunk requests (want a few, bounded)", peer.chunks)
        local before = peer.chunks
        sim.run({ maxTime = 600 })
        H.check(peer.chunks == before, "devices keep asking for refused files (%d more chunk requests)", peer.chunks - before)
        for _, c in ipairs({ A.c, P.c }) do H.check(c.alive, "#%d stopped: %s", c.id, tostring(c.err)) end
        return string.format("GitHub + hand-edited broken files not signed; broken / tampered releases from a member refused by all 4 devices (%d chunk requests, then none)", peer.chunks)
    end,
}
