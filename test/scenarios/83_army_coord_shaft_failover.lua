-- Version: 1.0.0
-- Scenario 83 (army coordinator): long shaft waits trigger a dig_shaft job (once); claims, locks and
-- the second shaft survive a leader failover (replicated), and the new leader never reassigns.
return {
    title = "army coordinator: second-shaft trigger and failover keeps claims",
    needs = { "net" },
    run = function(sim, H)
        local wired = { side = "back", kind = "wired", net = "base" }
        local L = H.serverComputer({ id = 10, modems = { wired } })
        local R = H.serverComputer({ id = 12, modems = { wired } })
        sim.run({ maxTime = 20 })
        H.check(L.role() == "leader" and R.role() == "replica", "roles %s %s", L.role(), R.role())
        local A = L.T.army
        local sent = {}
        A.out = function(kind, to, body) sent[#sent + 1] = { kind = kind, to = to, body = body } end
        local function ask(id, now, kind, body)
            sent = {}
            body = body or {}
            body.kind, body.from, body.name = kind, id, "r"
            A.handle(body, now)
            return sent[1] and sent[1].body
        end
        local now = L.T.now()
        local army = assert(A.new("r", { x = 0, y = 64, z = 0, f = 0 }, { "diamond" }, nil, now))
        A.handle({ kind = "army_set", from = 0, name = "r", key = "SHAFT_WAIT_S", value = 30 }, now)
        for id = 1, 4 do A.handle({ kind = "army_join", from = id, name = "r", at = { x = 0, y = 64, z = 0 } }, now) end
        for i = 1, 4 do   -- 4 waits of ~90 s on the shaft
            local t0 = now + i * 1000
            ask(1, t0, "seg_req", { segs = { "s1:0" }, dir = "down" })
            ask(2, t0, "seg_req", { segs = { "s1:0" }, dir = "up" })
            ask(1, t0 + 100, "seg_release", { segs = { "s1:0" } })
            ask(2, t0 + 90000, "seg_req", { segs = { "s1:0" }, dir = "up" })
            ask(2, t0 + 90100, "seg_release", { segs = { "s1:0" } })
        end
        H.check(army.wait.avgMs > 40000, "avg wait %s", army.wait.avgMs)
        local c = ask(3, now + 200000, "claim_req")
        H.check(c.dig_shaft == 2, "no dig_shaft job (%s)", tostring(c.key))
        local c4 = ask(4, now + 200001, "claim_req")
        H.check(c4.key, "second turtle should get a branch, not a second dig_shaft")
        local key1 = ask(1, now + 200002, "claim_req").key
        sim.run({ maxTime = 8 })
        H.check(R.T.S.armies.r and R.T.S.armies.r.branches[key1] and R.T.S.armies.r.shafts[2].digger == 3,
            "claims/digger not replicated")
        ask(3, now + 300000, "claim_done", { key = "shaft:2", step = 0 })
        H.check(army.shafts[2].done, "shaft 2 not marked done")
        H.check(ask(2, now + 300001, "seg_req", { segs = { "s1:0" }, dir = "up" }).wait, "up on shaft 1 allowed after shaft 2")
        sim.run({ maxTime = 8 })
        L.kill()
        local tNew
        sim.run({ maxTime = 40, untilFn = function()
            if R.role() == "leader" then tNew = tNew or sim.now end
            return tNew ~= nil and sim.now - tNew > 2
        end })
        H.check(R.role() == "leader", "no takeover")
        local A2 = R.T.army
        local sent2 = {}
        A2.out = function(kind, to, body) sent2[#sent2 + 1] = { kind = kind, to = to, body = body } end
        local a2 = R.T.S.armies.r
        H.check(a2 and a2.shafts[2].done and a2.branches[key1] and a2.branches[key1].tid == 1, "new leader lost state")
        A2.handle({ kind = "claim_req", from = 1, name = "r" }, R.T.now())
        H.check(sent2[1] and sent2[1].body.key == key1, "new leader reassigned turtle 1's branch")
        sent2 = {}
        A2.handle({ kind = "claim_req", from = 2, name = "r" }, R.T.now())
        H.check(sent2[1].body.key and sent2[1].body.key ~= key1, "duplicate claim after failover")
        return "dig_shaft once, state survived failover"
    end,
}
