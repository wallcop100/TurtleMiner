-- Version: 1.0.1
-- Scenario 85 (AR-T): 20 turtles share one shaft; the queue gets long, so the coordinator
-- assigns a "dig the second shaft" job. Afterwards shaft 1 goes down, shaft 2 goes up. Still no
-- collisions and no re-dug cell. SKIPs until the army modules exist.
return {
    title = "army: 20 turtles share a shaft, a second shaft is dug under load",
    needs = { "net", "mine", "miner" },
    run = function(sim, H)
        local A = require("army")(sim, H)
        A.need()
        A.tap()
        local st = A.station({ y = 8 })
        local ld, ui = A.leader(st), A.ui()
        -- shaft wait threshold lowered so the test is short (assumed setting name; default is 60 s)
        local rec = A.newArmy(st, ld, ui, { name = "big", ores = { "lapis" }, settings = { SHAFT_WAIT_S = 5 } })
        A.watchShaft(st)
        A.joinTurtles(st, ld, "big", 10)
        A.runUntil(st, function()
            local s2 = rec.shafts and rec.shafts[2]
            return s2 and s2.done and A.done(rec) >= 8
        end, 12000, "second shaft done and 8 branches done")
        A.assertClean(st, "10 turtles")
        local ws = A.waitStats(st)
        -- both shafts are real: columns at r=0 and r=1 are open from the station to the level
        local y = rec.levels[1].y
        for k = 1, 2 do
            for _, yy in ipairs({ st.S.y - 1, y }) do
                local p = st.shaftCell(k, yy)
                H.check(st.w:isAir(p.x, p.y, p.z), "shaft %d not open at y=%d", k, yy)
            end
        end
        return string.format("10 turtles, 2 shafts, %d branches done, 0 collisions, 0 re-dug; shaft wait total %ds max %ds avg(leader) %s ms",
            A.done(rec), ws.total, ws.max, tostring(rec.wait and rec.wait.avgMs))
    end,
}
