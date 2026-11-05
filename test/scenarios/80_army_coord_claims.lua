-- Version: 1.0.0
-- Scenario 80 (army coordinator): 100 claims over 3 levels come out nearest-first, on both sides
-- of the shaft and both corridor signs, with no branch given twice.
local BASIC = { { side = "back", kind = "basic" } }

return {
    title = "army coordinator: 100 nearest-first claims across levels, no duplicates",
    needs = { "net" },
    run = function(sim, H)
        local srv = H.serverComputer({ id = 1, modems = BASIC })
        sim.run({ maxTime = 25 })
        H.check(srv.role() == "leader", "role %s", srv.role())
        local A = srv.T.army
        H.check(A, "tm_army not loaded")
        local sent = {}
        A.out = function(kind, to, body) sent[#sent + 1] = { kind = kind, to = to, body = body } end
        local now = 1000000
        local army = assert(A.new("alpha", { x = 100, y = 64, z = 200, f = 1 }, { "iron", "gold", "diamond", "redstone" }, nil, now))
        H.check(#army.levels == 3 and army.levels[1].y == -58 and #army.levels[1].focus == 2, "levels wrong")
        A.handle({ kind = "army_set", from = 0, name = "alpha", key = "geom.bl", value = 8 }, now)
        A.handle({ kind = "army_set", from = 0, name = "alpha", key = "geom.ml", value = 10 }, now)
        for id = 1, 100 do
            A.handle({ kind = "army_join", from = id, name = "alpha", at = { x = 100, y = 64, z = 200, f = 1 } }, now)
        end
        H.check(next(army.members) and #A.cfgOf(army).levels == 3, "join failed")
        local seen, lastCost, lv, cs, sides = {}, -1, {}, {}, {}
        for id = 1, 100 do
            sent = {}
            A.handle({ kind = "claim_req", from = id, name = "alpha", pos = { x = 100, y = 64, z = 200 }, fuel = 5000 }, now + id)
            local c = sent[1] and sent[1].body
            H.check(c and c.key, "turtle %d got no claim", id)
            H.check(not seen[c.key], "branch %s given twice", c.key)
            seen[c.key] = true
            local y, cc, b, side = A.parseKey(c.key)
            local cost = A.cost(army, y, cc, b)
            H.check(cost >= lastCost, "claim %d cost %s after %s", id, cost, lastCost)
            lastCost = cost
            lv[y], cs[cc > 0 and "+" or cc < 0 and "-" or "0"], sides[side] = true, true, true
            H.check(c.geom.bl == 8 and c.level.y == y, "claim body wrong")
        end
        local nl = 0
        for _ in pairs(lv) do nl = nl + 1 end
        H.check(nl >= 2, "only %d level(s) used", nl)
        H.check(cs["+"] and cs["-"] and cs["0"] and sides.L and sides.R, "missing a side/corridor sign")
        return "100 unique claims, costs non-decreasing, " .. nl .. " levels"
    end,
}
