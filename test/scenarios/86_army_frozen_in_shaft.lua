-- Version: 1.0.0
-- Scenario 86 (AR-T): a turtle in an unloaded chunk (frozen) stands in the shaft. Others wait
-- (no collision, nothing dug through it), the leader never reassigns its claim or segments, and
-- army_release frees them. Once it runs again the army carries on. SKIPs until the army modules exist.
return {
    title = "army: frozen turtle in the shaft; others wait, claim kept, army_release works",
    needs = { "net", "mine", "miner" },
    run = function(sim, H)
        local A = require("army")(sim, H)
        A.need()
        A.tap()
        local st = A.station({ y = 8 })
        local ld, ui = A.leader(st), A.ui()
        local rec = A.newArmy(st, ld, ui, { name = "fz", ores = { "lapis" } })
        A.joinTurtles(st, ld, "fz", 5)
        local victim
        A.runUntil(st, function()
            for _, t in ipairs(st.turtles) do
                if A.inShaft(st, t) and t.pos.y < st.S.y - 4 then
                    local br = A.held(rec, t.id)
                    if #br > 0 then victim = t; return true end
                end
            end
        end, 3000, "a turtle with a claim inside the shaft")
        sim.freeze(victim)
        local br0, sg0 = A.held(rec, victim.id)
        H.check(#sg0 > 0, "the turtle in the shaft holds no segment")
        local done0, pos0 = A.done(rec), sim.copyPos(victim.pos)
        sim.run({ maxTime = 900 })
        local br1, sg1 = A.held(rec, victim.id)
        H.check(table.concat(br1, ",") == table.concat(br0, ","), "claim reassigned: %s -> %s", table.concat(br0, ","), table.concat(br1, ","))
        H.check(table.concat(sg1, ",") == table.concat(sg0, ","), "segments reassigned: %s -> %s", table.concat(sg0, ","), table.concat(sg1, ","))
        H.check(H.samePos(victim.pos, pos0), "frozen turtle moved")
        A.assertClean(st, "while frozen")
        -- release from the monitor
        ui.send("army_release", { name = "fz", tid = victim.id })
        sim.run({ maxTime = 10 })
        local br2, sg2 = A.held(rec, victim.id)
        H.check(#br2 == 0 and #sg2 == 0, "army_release left %d claims %d segments", #br2, #sg2)
        -- the chunk loads again: the army carries on, still without a collision
        sim.thaw(victim)
        A.runUntil(st, function() return A.done(rec) >= done0 + 3 end, 4000, "progress after release/thaw")
        A.assertClean(st, "after thaw")
        return string.format("frozen turtle %d kept claim %s and %d segs for 900 s, 0 collisions; release freed them; %d branches done after thaw",
            victim.id, br0[1], #sg0, A.done(rec))
    end,
}
