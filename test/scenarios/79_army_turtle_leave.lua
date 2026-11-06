-- Version: 1.0.0
-- Scenario 79 (AR-2): a turtle leaves the army (ARMY_LEAVE) after its branch, returns to the station
-- and is back in solo mode (no membership, nothing held).
return {
    title = "army turtle: leave finishes the branch and returns to solo",
    needs = { "net", "mine", "miner", "group" },
    run = function(sim, H)
        local A = require("army")(sim, H)
        A.need()
        local st = A.station({ x = 100, y = 8, z = 100, f = 0 })
        local ld, ui = A.leader(st), A.ui()
        local rec = A.newArmy(st, ld, ui, { name = "lv", ores = { "lapis" } })
        local t = A.addTurtle(st, "lv", { gps = true })
        A.runUntil(st, function() return rec.members and rec.members[t.id] and A.done(rec) >= 1 end, 3000, "first branch")
        ui.srv.cmd(t.id, "ARMY_LEAVE", {})
        A.runUntil(st, function() return not rec.members[t.id] end, 3000, "removed from the army")
        A.runUntil(st, function() return H.samePos(t.pos, st.spot()) end, 2000, "back at the station")
        local held, segs = A.held(rec, t.id)
        H.check(#held == 0 and #segs == 0, "still holds %d branches, %d segments", #held, #segs)
        return "left the army, back at the station spot, nothing held"
    end,
}
