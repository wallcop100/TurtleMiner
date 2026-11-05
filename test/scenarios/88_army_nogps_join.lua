-- Version: 1.0.0
-- Scenario 88 (AR-T): a turtle without GPS joins at the station spot and adopts the station's
-- world coordinates as its home. Its reported positions are world coordinates, and it digs its
-- claimed branches where the station frame says. SKIPs until the army modules exist.
return {
    title = "army: a no-GPS turtle joins at the station and works in world coordinates",
    needs = { "net", "mine", "miner" },
    run = function(sim, H)
        local A = require("army")(sim, H)
        A.need()
        local st = A.station({ x = 240, y = 8, z = -75, f = 1 })     -- far from 0,0,0 and facing east
        local ld, ui = A.leader(st), A.ui()
        local rec = A.newArmy(st, ld, ui, { name = "ng", ores = { "lapis" } })
        local t = A.addTurtle(st, "ng", { gps = false })
        A.runUntil(st, function() return rec.members and rec.members[t.id] end, 300, "join")
        local checked, bad = 0, nil
        sim.every(3, function()
            local r = ld.rec(t.id)
            local p = r and r.st and r.st.pos
            if p and not H.samePos(t.pos, st.spot()) then
                checked = checked + 1
                local d = math.abs(p.x - t.pos.x) + math.abs(p.y - t.pos.y) + math.abs(p.z - t.pos.z)   -- status is up to STATUS_INTERVAL old
                if d > 60 and not bad then
                    bad = string.format("t=%.0f reports %s, truth %s", sim.now, H.fmtPos(p), H.fmtPos(t.pos))
                end
            end
        end, 3)
        A.runUntil(st, function() return A.done(rec) >= 2 end, 4000, "2 branches done")
        H.check(checked > 5, "no usable status samples (%d)", checked)
        H.check(not bad, "position is not in world coordinates: %s", tostring(bad))
        -- the mains of the done branches were dug where the station frame says
        local y = rec.levels[1].y
        local W = 2 * rec.geom.bl + rec.geom.sp
        local seen = 0
        for key, b in pairs(rec.branches) do
            local yy, c = key:match("^(-?%d+):(-?%d+):")
            if b.state == "done" and tonumber(yy) == y then
                local p = st.toWorld(2, tonumber(c) * W, y)
                H.check(st.w:isAir(p.x, p.y, p.z), "main cell for %s not dug at %s", key, H.fmtPos(p))
                seen = seen + 1
            end
        end
        H.check(seen >= 1, "no done branch on level %d", y)
        A.assertClean(st, "no-GPS turtle")
        return string.format("no-GPS turtle joined at %s facing %d, %d status samples in world coordinates, %d branches done",
            H.fmtPos(st.S), st.S.f, checked, A.done(rec))
    end,
}
