-- Version: 1.1.0
-- Scenario 54 (MU-0): forged, tampered, replayed and stale messages are rejected.
--  A (turtle, real net.lua): commands that are unsigned, signed with another key, tampered
--    after signing, replayed (same copy again; same signature under a new seq), 11 minutes
--    old or 11 minutes in the future: none applied, none acked. A good one: applied once.
--  B (server, real tminer_server): a catch-up log 20 minutes old is accepted (its events carry
--    signed timestamps); a status 11 minutes old is not.
--  Forged / foreign updates: scenario 60 (mesh updates, MU-1).
return {
    title = "forged / tampered / replayed / stale messages rejected",
    needs = { "net", "tmcrypto" },
    run = function(sim, H)
        local netB = H.network("other", { "river", "torch", "birch", "creek" })
        local w = sim.world()
        local srv = H.server({ id = 100 })
        local t = sim.turtle(w, { id = 1, pos = { x = 0, y = 0, z = 0 } })
        local c = H.netTurtle(t, "T1")
        sim.run({ maxTime = 12 })
        local seq = 5000
        local function cmdMsg(id, cmd, extra)
            seq = seq + 1
            local m = { v = 1, kind = "cmd", from = 100, to = 1, boot = sim.BASE_EPOCH + 1, seq = seq,
                ts = H.epochMs(), hops = 0, hop = 0, ohop = 0, mk = "ender", id = id, cmd = cmd, params = {} }
            for k, v in pairs(extra or {}) do m[k] = v end
            return m
        end
        local function inject(m) sim.net.inject(100, nil, m, "TMINER"); sim.run({ maxTime = 2 }) end
        local function acked(id) return srv.acks[id] ~= nil end

        -- A: forged ----------------------------------------------------------------------
        local bad0 = c.net.stats.bad
        inject(cmdMsg("u1", "PAUSE"))                                     -- unsigned
        inject(H.sign(cmdMsg("f1", "PAUSE"), netB))                       -- other network's key
        local fake = H.sign(cmdMsg("f2", "PAUSE"), netB)
        fake.net = H.C.netTag(H.NET.key)                                  -- our tag, wrong key
        inject(fake)
        local tm = H.sign(cmdMsg("t1", "PAUSE"))
        tm.cmd = "RETURN_HOME"                                            -- tampered after signing
        inject(tm)
        local tm2 = H.sign(cmdMsg("t2", "PAUSE"))
        tm2.hops, tm2.hop, tm2.mk = 2, 1, "basic"                         -- relay fields: still fine
        inject(tm2)
        H.check(H.appliedCount(c, "PAUSE") == 1 and acked("t2"), "relayed copy (hops/hop/mk changed) rejected")
        inject(H.sign(cmdMsg("o1", "RESUME", { ts = H.epochMs() - 11 * 60000 })))   -- too old
        inject(H.sign(cmdMsg("o2", "RESUME", { ts = H.epochMs() + 11 * 60000 })))   -- future
        H.check(H.appliedCount(c, "RETURN_HOME") == 0 and H.appliedCount(c, "RESUME") == 0
            and H.appliedCount(c, "PAUSE") == 1, "forged command applied: %s", (function()
                local o = {} for _, a in ipairs(c.applied) do o[#o + 1] = a.cmd .. "(" .. tostring(a.id) .. ")" end
                return table.concat(o, " ") end)())
        for _, id in ipairs({ "u1", "f1", "f2", "t1", "o1", "o2" }) do
            H.check(not acked(id), "turtle acked forged command %s", id)
        end
        H.check(c.net.stats.bad - bad0 >= 6, "bad messages counted %d", c.net.stats.bad - bad0)

        -- Replay: the same copy again (dedupe), and its signature under a new seq.
        local good = H.sign(cmdMsg("r1", "REQUEST_STATUS"))
        inject(good)
        local acks1 = #(srv.acks["r1"] or {})
        H.check(H.appliedCount(c, "REQUEST_STATUS") == 1 and acks1 == 1, "good command: applied %d, acks %d",
            H.appliedCount(c, "REQUEST_STATUS"), acks1)
        local again = {}
        for k, v in pairs(good) do again[k] = v end
        inject(again)
        H.check(#(srv.acks["r1"] or {}) == 1, "replayed copy acked again")
        again = {}
        for k, v in pairs(good) do again[k] = v end
        again.seq = again.seq + 1000
        inject(again)
        H.check(H.appliedCount(c, "REQUEST_STATUS") == 1 and #(srv.acks["r1"] or {}) == 1,
            "replay under a new seq accepted")

        -- B: server side: old catch-up accepted, old status not ------------------------
        local S = H.serverComputer({ id = 10 })
        sim.run({ maxTime = 5 })
        local function fromTurtle(id, kind, body, tsAgo)
            seq = seq + 1
            local m = { v = 1, kind = kind, from = id, to = "server", boot = sim.BASE_EPOCH + 2, seq = seq,
                ts = H.epochMs() - tsAgo, hops = 0, ohop = 1, mk = "ender" }
            for k, v in pairs(body) do m[k] = v end
            sim.net.inject(id, nil, H.sign(m), "TMINER")
            sim.run({ maxTime = 1 })
        end
        fromTurtle(6, "status", { label = "Stale", phase = "MINING" }, 11 * 60000)
        H.check(S.rec(6) == nil, "server accepted an 11 min old status")
        local evTs = H.epochMs() - 20 * 60000
        fromTurtle(7, "catchup", { events = { { eid = "7:1:1", ts = evTs, last = evTs, n = 1, level = "info",
            text = "vein iron x4" } }, dropped = 0 }, 20 * 60000)
        H.check(S.logText():find("vein iron x4 (catch-up)", 1, true), "old catch-up rejected:\n%s", S.logText())
        H.check(S.T.S.bad >= 1, "server did not count the stale status")
        S.kill()

        H.note(string.format("A: 6 forged cmds dropped (bad=%d), relayed copy ok, replays ignored; B: 20 min old catch-up"
            .. " logged, 11 min old status dropped", c.net.stats.bad))
    end,
}
