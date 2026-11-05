-- Version: 1.0.0
-- Scenario 78 (AR-2): two turtles share one shaft; they only meet through granted segments (no collision).
return {
    title = "army turtles: two turtles in one shaft, no collisions",
    needs = { "net", "mine", "miner", "group" },
    run = function(sim, H)
        local A = require("army")(sim, H)
        A.need()
        local st = A.station({ x = 100, y = 8, z = 100, f = 2 })
        local ld, ui = A.leader(st), A.ui()
        local rec = A.newArmy(st, ld, ui, { name = "duo", ores = { "lapis" } })
        A.joinTurtles(st, ld, "duo", 2, { gps = true })
        A.runUntil(st, function() return A.done(rec) >= 4 end, 6000, "4 branches done")
        A.assertClean(st, "two turtles")
        return string.format("2 turtles, %d branches done, 0 collisions", A.done(rec))
    end,
}
