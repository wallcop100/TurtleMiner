-- Version: 1.0.0
-- Scenario 84 (AR-T): 4 turtles of one army mine two levels (lapis 0, gold -16) from one shared
-- shaft. Nobody bumps into anybody and no cell is dug twice. SKIPs until servers/tm_army.lua
-- and miner/group.lua exist.
return {
    title = "army: 4 turtles, 2 levels, 0 collisions, 0 re-dug cells",
    needs = { "net", "mine", "miner" },
    run = function(sim, H)
        local A = require("army")(sim, H)
        A.need()
        A.tap()
        local st = A.station({ y = 8 })
        local ld, ui = A.leader(st), A.ui()
        local rec = A.newArmy(st, ld, ui, { name = "alpha", ores = { "lapis", "gold" } })
        H.check(#rec.levels == 2, "expected 2 levels, got %d", #rec.levels)
        A.watchShaft(st)
        A.joinTurtles(st, ld, "alpha", 4)
        local y1, y2 = rec.levels[1].y, rec.levels[2].y
        A.runUntil(st, function() return A.done(rec, y1) >= 3 and A.done(rec, y2) >= 3 end, 6000, "3 branches done on each level")
        local c = A.assertClean(st, "4 turtles")
        local ws = A.waitStats(st)
        return string.format("%d branches done (%d/%d per level), 0 collisions, 0 re-dug; %d digs; shaft wait total %ds max %ds",
            A.done(rec), A.done(rec, y1), A.done(rec, y2), c.digs, ws.total, ws.max)
    end,
}
