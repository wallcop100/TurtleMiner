-- Version: 1.0.0
-- Scenario 73 (CG-3): no anchor at all (no other GPS, no turtles). After the confirm only the PCs
-- that settle the layout are asked, on their own terminal: three give "X Y Z" and one gives a
-- single number (it tells the mirror image apart); the fifth PC is worked out silently. Every
-- entry is checked against the measured distances at once: a typo is rejected with the
-- distance that does not fit and the prompt stays.
local function pc(id, x, y, z, mon)
    local o = { id = id, pos = { x = x, y = y, z = z }, modems = { { side = "back", kind = "basic" } } }
    if mon then o.monitor = { side = "top", w = 39, h = 14 } end
    return o
end

return {
    title = "GPS fallback: only the needed PCs are asked, a typo is rejected at once",
    needs = { "net" },
    run = function(sim, H)
        local spec = { pc(1, 0, 70, 0, true), pc(2, 20, 70, 0), pc(3, 0, 70, 15), pc(4, 5, 80, 5), pc(5, -25, 70, 0) }
        local all, byId = {}, {}
        for _, o in ipairs(spec) do local S = H.serverComputer(o); all[#all + 1] = S; byId[o.id] = S end
        local A = all[1]
        sim.run({ maxTime = 80 })
        H.check(A.T.gps.view.st == "offer", "state %s", A.T.gps.view.st)
        H.uiPress(A, "Set up")
        sim.run({ maxTime = 12 })
        H.check(A.T.gps.view.st == "asking", "state %s", A.T.gps.view.st)
        local asked = {}
        for id, a in pairs(A.T.gps.view.asks) do H.check(a.kind == "xyz", "first asks are full coordinates"); asked[#asked + 1] = id end
        table.sort(asked)
        H.check(#asked == 3, "%d PCs asked (want 3)", #asked)
        local mon = A.c.peripherals.top.screen
        H.check(mon._text():find("waiting for", 1, true), "monitor does not show who is waited for:\n%s", mon._text())
        local function xyz(S, dx) local p = S.c.pos; return string.format("%d %d %d", p.x + (dx or 0), p.y, p.z) end
        local function lastScreen(S) return S.c.term._text() end

        H.uiType(byId[asked[1]], xyz(byId[asked[1]]))
        H.uiType(byId[asked[2]], xyz(byId[asked[2]]))
        sim.run({ maxTime = 1 })
        H.check(not A.T.gps.view.asks[asked[1]] and not A.T.gps.view.asks[asked[2]], "good entries not accepted")
        -- typo on the third (3 blocks off): rejected, prompt stays, the measured distance is named
        local third = byId[asked[3]]
        H.uiType(third, xyz(third, 3))
        sim.run({ maxTime = 1 })
        H.check(A.T.gps.view.asks[asked[3]] ~= nil and A.T.gps.view.st == "asking", "typo accepted")
        H.check(lastScreen(third):find("doesn't match", 1, true) and lastScreen(third):find("should be", 1, true),
            "no rejection on the terminal:\n%s", lastScreen(third))
        H.check(lastScreen(third):find("Targeted", 1, true), "prompt gone after a typo")
        H.uiType(third, xyz(third))
        sim.run({ maxTime = 2 })
        -- now one number from the PC that tells the mirror image apart
        local axisPc, axis
        for id, a in pairs(A.T.gps.view.asks) do axisPc, axis = byId[id], a end
        H.check(axisPc and axis.kind == "axis", "no axis question: %s", sim.textutils.serialize(A.T.gps.view.asks))
        local truth = axisPc.c.pos[axis.axis]
        local wrong = truth + 7
        H.uiType(axisPc, tostring(wrong))
        sim.run({ maxTime = 1 })
        H.check(A.T.gps.view.asks[axisPc.c.id] ~= nil and lastScreen(axisPc):find("doesn't match", 1, true),
            "wrong number accepted:\n%s", lastScreen(axisPc))
        H.uiType(axisPc, tostring(truth))
        sim.run({ maxTime = 4 })

        for _, S in ipairs(all) do
            local v = S.T.gps.view
            H.check(v.st == "on" and next(v.asks) == nil, "#%d state %s", S.c.id, v.st)
            local h = v.hosts[S.c.id]
            local p = S.c.pos
            H.check(h and h.st == "hosting" and h.x == p.x and h.y == p.y and h.z == p.z, "#%d hosts as %s (real %d,%d,%d)",
                S.c.id, h and (h.x .. "," .. h.y .. "," .. h.z) or "nothing", p.x, p.y, p.z)
        end
        H.check(not lastScreen(all[5]):find("Targeted", 1, true), "the fifth PC was asked")
        return "4 of 5 PCs asked (3 X Y Z + 1 number), typo and wrong number rejected with the measured distance, 5th worked out; all hosts exact"
    end,
}
