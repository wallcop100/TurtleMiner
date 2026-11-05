-- Version: 1.0.0
-- Scenario 81 (army coordinator): a silent holder keeps its branch for ever; army_release frees it;
-- claim_done stores extra digs + stats and nearExtras finds them around a branch.
local BASIC = { { side = "back", kind = "basic" } }

return {
    title = "army coordinator: silent turtle's claim never reassigned, release frees it, extras in near",
    needs = { "net" },
    run = function(sim, H)
        local srv = H.serverComputer({ id = 1, modems = BASIC })
        sim.run({ maxTime = 25 })
        local A = srv.T.army
        local sent = {}
        A.out = function(kind, to, body) sent[#sent + 1] = { kind = kind, to = to, body = body } end
        local function ask(id, now, kind, body)
            sent = {}
            body = body or {}
            body.kind, body.from, body.name = kind, id, "beta"
            A.handle(body, now)
            return sent[1] and sent[1].body
        end
        local now = 5000000
        local army = assert(A.new("beta", { x = 0, y = 64, z = 0, f = 0 }, { "diamond" }, nil, now))
        for id = 1, 3 do A.handle({ kind = "army_join", from = id, name = "beta", at = { x = 0, y = 64, z = 0, f = 0 } }, now) end
        A.handle({ kind = "army_join", from = 9, name = "beta", at = { x = 1, y = 64, z = 0 } }, now)
        H.check(not army.members[9], "joined away from the station")
        local c1 = ask(1, now, "claim_req")
        local key1 = c1.key
        -- turtle 1 goes silent for a day; the others work on
        local later = now + 86400000
        for i = 1, 30 do
            local c = ask(2, later + i, "claim_req")
            H.check(c.key ~= key1, "silent holder's branch %s reassigned", key1)
            ask(2, later + i, "claim_done", { key = c.key, step = 32, ores = { diamond = 2 },
                extra = { "5,-58,-9", "6,-58,-9" }, fuelUsed = 40 })
        end
        H.check(army.stats.branchesDone == 30 and army.stats.ores.diamond == 60 and army.stats.fuelUsed == 1200, "stats wrong")
        H.check(army.extra["5,-58,-9"], "extra digs not stored")
        local again = ask(1, later, "claim_req")
        H.check(again.key == key1, "holder did not get its own branch back (%s)", tostring(again.key))
        A.handle({ kind = "army_release", from = 0, name = "beta", tid = 1 }, later)
        H.check(not army.branches[key1], "release did not free the branch")
        local c3 = ask(3, later, "claim_req")
        H.check(c3.key == key1, "freed branch not handed out first (%s)", tostring(c3.key))
        local y, c, b, side = A.parseKey(key1)
        local box = A.branchBox(army, y, c, b, side)
        army.extra[box.x1 .. "," .. y .. "," .. (box.z1 + 2)] = later
        local near = A.nearExtras(army, y, c, b, side, 3)
        H.check(#near >= 1, "no near extras for %s", key1)
        return "silent claim kept, released claim reissued, " .. #near .. " near extra(s)"
    end,
}
