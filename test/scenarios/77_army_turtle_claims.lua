-- Version: 1.0.0
-- Scenario 77 (AR-2): one turtle standing on the station spot with GROUP set joins, claims a branch, mines it,
-- reports claim_done (ores / extra digs), and gets the next branch.
return {
    title = "army turtle: join at the station, claim, mine, claim_done, next claim",
    needs = { "net", "mine", "miner", "group" },
    run = function(sim, H)
        local A = require("army")(sim, H)
        A.need()
        local st = A.station({ x = 100, y = 8, z = 100, f = 0 })
        local ld, ui = A.leader(st), A.ui()
        local rec = A.newArmy(st, ld, ui, { name = "solo1", ores = { "lapis" } })
        local y = rec.levels[1].y
        -- an ore vein beside the first branch: its cells must come back as extra digs
        local p = st.toWorld(2 + 3, 3, y + 1)
        for i = 0, 2 do st.w:set(p.x, p.y + i, p.z, "minecraft:deepslate_lapis_ore") end
        local t = A.addTurtle(st, "solo1", { gps = true })
        A.runUntil(st, function() return rec.members and rec.members[t.id] end, 300, "join")
        A.runUntil(st, function() return A.done(rec) >= 2 end, 4000, "2 branches done")
        local ores = 0
        for _, v in pairs(rec.stats.ores) do ores = ores + v end
        H.check(rec.stats.branchesDone >= 2, "branchesDone %d", rec.stats.branchesDone)
        A.assertClean(st, "one turtle")
        return string.format("joined, %d branches done, %d ore blocks and %d extra digs reported", A.done(rec), ores,
            (function() local n = 0 for _ in pairs(rec.extra) do n = n + 1 end return n end)())
    end,
}
