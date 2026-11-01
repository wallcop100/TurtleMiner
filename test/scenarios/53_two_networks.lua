-- Version: 1.0.0
-- Scenario 53 (MU-0): two players' mining networks on the same airwaves (ender modems, all in
-- range of each other). Player A: server PC #10 + turtles #1, #2. Player B (another key):
-- server PC #20, relay computer #21, turtle #3.
--  * each server only lists its own turtles; each counts the other's traffic as foreign
--  * B's server sends PAUSE to A's turtle #1: never applied; A's own PAUSE is applied once
--  * B's relay never relays A's traffic (and does relay B's)
--  * A's turtles never relay B's traffic
return {
    title = "two networks share the airwaves without seeing each other",
    needs = { "net", "tmcrypto" },
    needsFile = "servers/relay.lua",
    run = function(sim, H)
        local f = assert(io.open(sim.REPO .. "/servers/relay.lua", "rb"))
        local relaySrc = f:read("a")
        f:close()
        local netB = H.network("other", { "river", "torch", "birch", "creek" })
        local tagA, tagB = H.C.netTag(H.NET.key), H.C.netTag(netB.key)
        H.check(tagA ~= tagB, "network tags collide")

        local w = sim.world()
        local A = H.serverComputer({ id = 10 })
        local B = H.serverComputer({ id = 20, network = netB })
        local relayB = sim.computer({ id = 21, network = netB })
        relayB.fs:write("relay.lua", relaySrc)
        H.installShared(relayB)
        sim.boot(relayB, { "relay" }, { background = true })
        local tA1 = sim.turtle(w, { id = 1, pos = { x = 0, y = 0, z = 0 } })
        local tA2 = sim.turtle(w, { id = 2, pos = { x = 5, y = 0, z = 0 } })
        local tB3 = sim.turtle(w, { id = 3, pos = { x = 9, y = 0, z = 0 }, network = netB })
        local cA1, cA2, cB3 = H.netTurtle(tA1, "A1"), H.netTurtle(tA2, "A2"), H.netTurtle(tB3, "B3")
        sim.run({ maxTime = 30 })

        H.check(A.rec(1) and A.rec(2) and not A.rec(3), "A's server lists %s", table.concat((function()
            local ids = {} for id in pairs(A.T.S.turtles) do ids[#ids + 1] = "#" .. id end return ids end)(), " "))
        H.check(B.rec(3) and not B.rec(1) and not B.rec(2), "B's server lists A's turtles")
        H.check(A.T.S.bad > 0 and B.T.S.bad > 0, "foreign messages not counted (A %d, B %d)", A.T.S.bad, B.T.S.bad)
        H.check(cA1.net.stats.bad > 0, "A's turtle did not count B's traffic as foreign")

        -- B tries to command A's turtle #1 (B's server never heard it: queued, then sent when
        -- "heard" -- it never is). Force a direct send too.
        local t0 = sim.now
        B.T.issueCmd(1, "PAUSE", {})
        B.T.send("cmd", 1, { id = "evil-1", cmd = "RETURN_HOME", params = {} })
        sim.run({ maxTime = 20 })
        H.check(H.appliedCount(cA1, "PAUSE") == 0 and H.appliedCount(cA1, "RETURN_HOME") == 0,
            "A's turtle obeyed B's command")
        A.T.issueCmd(1, "PAUSE", {})
        sim.run({ maxTime = 10 })
        H.check(H.appliedCount(cA1, "PAUSE") == 1, "A's own PAUSE applied %d times", H.appliedCount(cA1, "PAUSE"))

        -- Relays: B's relay forwards only B's traffic; A's turtles never forward B's.
        local relayedA, relayedB, turtleRelayedB = 0, 0, 0
        for _, e in ipairs(sim.net.log) do
            local m = e.msg
            if type(m) == "table" and e.from ~= m.from then
                if e.from == 21 then
                    if m.net == tagA then relayedA = relayedA + 1 elseif m.net == tagB then relayedB = relayedB + 1 end
                elseif (e.from == 1 or e.from == 2) and m.net == tagB then
                    turtleRelayedB = turtleRelayedB + 1
                end
            end
        end
        H.check(relayedA == 0, "B's relay relayed %d of A's messages", relayedA)
        H.check(relayedB > 0, "B's relay relayed none of B's own messages")
        H.check(turtleRelayedB == 0, "A's turtles relayed %d of B's messages", turtleRelayedB)
        H.check(relayB.alive, "relay stopped: %s", tostring(relayB.err))
        H.note(string.format("A lists #1 #2, B lists #3; foreign msgs dropped: A %d, B %d, turtle #1 %d; B's relay: %d of B's relayed,"
            .. " 0 of A's; B's PAUSE ignored, A's applied once", A.T.S.bad, B.T.S.bad, cA1.net.stats.bad, relayedB))
    end,
}
