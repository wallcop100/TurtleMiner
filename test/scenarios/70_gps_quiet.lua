-- Version: 1.0.0
-- Scenario 70 (CG-3, docs/CLUSTER_GPS_PLAN.md section 3): GPS is offered only when it can work.
--   3 wireless PCs: nothing (no measuring, no hint on terminal or monitor).
--   a 4th PC in the same plane as the others: measured, judged flat, still silent.
--   the 4th PC raised 10 blocks: the offer appears (re-checked within a minute).
local function pc(id, x, y, z, mon)
    local o = { id = id, pos = { x = x, y = y, z = z }, modems = { { side = "back", kind = "basic" } } }
    if mon then o.monitor = { side = "top", w = 39, h = 14 } end
    return o
end

return {
    title = "GPS offer is silent with 3 PCs or 4 coplanar PCs, appears when the layout works",
    needs = { "net" },
    run = function(sim, H)
        local A = H.serverComputer(pc(1, 0, 70, 0, true))
        local B = H.serverComputer(pc(2, 20, 70, 0))
        local C = H.serverComputer(pc(3, 0, 70, 15))
        sim.run({ maxTime = 100 })
        local function offered(S) return S.T.gps.view.st == "offer" end
        H.check(A.role() == "leader", "leader is %s", A.role())
        H.check(not offered(A) and not offered(B), "offer with 3 PCs")
        H.check(H.sentBy(1, 0, 100, "gps_measure") == 0, "leader measured with only 3 PCs")
        local mon = A.c.peripherals.top.screen
        -- No offer or prompt, but a status line saying why GPS is off (user request 2026-11-05).
        local txt = mon._text() .. A.c.term._text()
        H.check(not txt:find("possible", 1, true) and not txt:find("Set up", 1, true), "GPS offer shown with 3 PCs")
        H.check(txt:find("GPS 3/4+pc", 1, true), "no GPS status in the footer with 3 PCs")

        local D = H.serverComputer(pc(4, 9, 70, 9))     -- same Y as the others: flat
        sim.run({ maxTime = 130 })
        H.check(H.sentBy(1, 100, 230, "gps_measure") >= 1, "no measurement with 4 PCs")
        H.check(not offered(A), "offered a flat layout")
        H.check(A.T.gps.view.note and A.T.gps.view.note:find("plane", 1, true), "reason: %s", tostring(A.T.gps.view.note))
        H.check(not mon._text():find("GPS possible", 1, true) and not D.c.term._text():find("GPS possible", 1, true),
            "banner shown for a flat layout")

        D.c.pos.y = 80                                   -- lift it: now 4 PCs in 3D
        sim.run({ maxTime = 90 })
        H.check(offered(A) and A.T.gps.view.n == 4, "no offer after the layout became good (%s)", A.T.gps.view.st)
        for _, S in ipairs({ B, C, D }) do
            H.check(offered(S), "#%d does not know the offer", S.c.id)
        end
        H.check(mon._text():find("GPS possible with 4 PCs", 1, true), "monitor shows no offer:\n%s", mon._text())
        H.check(D.c.term._text():find("GPS possible with 4 PCs", 1, true), "terminal of #4 shows no offer")
        return "silent with 3 PCs and with 4 coplanar PCs; offer with 4 PCs once one is raised"
    end,
}
