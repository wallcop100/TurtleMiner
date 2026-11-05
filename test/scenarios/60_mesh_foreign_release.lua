-- Version: 1.0.0
-- Scenario 60 (MU-1): foreign, unsigned and forged releases are ignored.
--   #10 server PC (/files/), #30 pocket, turtle #1 (net.lua + mesh). Fake peers offer
--   config.lua / tm_ui.lua / relay.lua 9.5.0:
--     #41 unsigned messages, #42 another player's network (its own valid key),
--     #43 our network's messages but release notes signed with the other key, plus a bad mark
--         signed with the other key against a release everyone runs,
--     #44 our network, but a release note changed after signing (version raised).
--   Nothing is installed or staged anywhere, nobody rolls back, the unsigned/foreign peers are
--   never even asked (their messages are dropped), no file transfer to #43/#44 starts.
return {
    title = "foreign / unsigned / forged releases ignored",
    needs = { "net", "tmmesh", "tmguard" },
    run = function(sim, H)
        local netB = H.network("other", { "river", "torch", "birch", "creek" })
        local A = H.meshComputer({ id = 10, role = "server", modems = { { side = "top", kind = "ender" } } })
        local P = H.meshComputer({ id = 30, role = "pocket", modems = { { side = "back", kind = "ender" } } })
        local w = sim.world()
        local tc = H.netTurtle(sim.turtle(w, { id = 1, pos = { x = 0, y = 0, z = 0 } }))
        sim.run({ maxTime = 30 })
        local files = {
            ["miner/config.lua"] = H.bump(H.repo("miner/config.lua"), "9.5.0"),
            ["servers/tm_ui.lua"] = H.bump(H.repo("servers/tm_ui.lua"), "9.5.0"),
            ["servers/relay.lua"] = H.bump(H.repo("servers/relay.lua"), "9.5.0"),
        }
        local netVer = H.repo("miner/net.lua"):match("^%-%- Version: ([%d%.]+)")
        local forgedMark = { t = "bad", ids = { "miner/net.lua@" .. netVer, "servers/tm_db.lua@" .. H.repo("servers/tm_db.lua"):match("^%-%- Version: ([%d%.]+)") },
            reason = "forged", by = 43, ts = H.epochMs() }
        forgedMark.sig = H.signer(netB).mac(forgedMark)
        local p41 = H.fakePeer({ id = 41, net = false, files = files })
        local p42 = H.fakePeer({ id = 42, net = netB, files = files })
        local p43 = H.fakePeer({ id = 43, noteNet = netB, files = files, marks = { forgedMark }, vs = { m = "aaaaaa", s = "aaaaaa", r = "aaaaaa", b = "aaaaaa" } })
        local p44 = H.fakePeer({ id = 44, files = files, noteEdit = function(n) n.version = "9.6.0" end })
        sim.run({ maxTime = 600 })
        local devs = { A.c, P.c, tc }
        for _, c in ipairs(devs) do
            local E = H.engineOf(c)
            H.check(E, "#%d has no mesh engine", c.id)
            for name in pairs(files) do
                if E.holds(name) then
                    local v = E.heldVersion(name)
                    H.check(v ~= "9.5.0" and v ~= "9.6.0", "#%d holds %s %s", c.id, name, tostring(v))
                end
            end
            for _, p in ipairs(E.pending()) do
                H.check(not files[p.repo], "#%d wants %s %s from a forged note", c.id, p.repo, tostring(p.want))
            end
            H.check(#E.badList() == 0, "#%d accepted the forged bad mark", c.id)
            H.check(E.ready() ~= "rollback", "#%d wants to roll back", c.id)
            for _, f in ipairs({ "config.lua", "tm_ui.lua", "files/config.lua", "files/relay.lua" }) do
                local v = H.verOf(c, f)
                H.check(v ~= "9.5.0" and v ~= "9.6.0", "#%d installed %s %s", c.id, f, tostring(v))
            end
            H.check(c.alive, "#%d stopped: %s", c.id, tostring(c.err))
        end
        H.check(p41.lists == 0 and p42.lists == 0, "unsigned/foreign peers were asked (%d, %d)", p41.lists, p42.lists)
        H.check(p43.lists > 0 and p44.lists > 0, "signed peers were never asked (test setup)")
        H.check(p43.chunks == 0 and p44.chunks == 0, "a transfer of a forged release started (%d, %d chunk requests)", p43.chunks, p44.chunks)
        H.check(A.T().S.bad > 0 and tc.net.stats.bad > 0, "unsigned/foreign messages not counted as bad")
        return string.format("4 forged sources: none installed/staged on 3 devices; foreign/unsigned never asked (bad: #10 %d, turtle %d); forged notes/mark rejected (%d+%d list requests, 0 transfers)",
            A.T().S.bad, tc.net.stats.bad, p43.lists, p44.lists)
    end,
}
