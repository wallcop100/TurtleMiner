-- Version: 1.0.0
-- Scenario 71 (CG-3): 4 well placed wireless PCs. The offer shows on the monitor and on every
-- PC's terminal; ONE confirm on a replica's keyboard sets up all (the banner clears everywhere,
-- the coordinate prompts go to the PCs that are needed). "Never" is remembered cluster-wide
-- and the GPS page turns it back on.
local function pc(id, x, y, z, mon)
    local o = { id = id, pos = { x = x, y = y, z = z }, modems = { { side = "back", kind = "basic" } } }
    if mon then o.monitor = { side = "top", w = 39, h = 14 } end
    return o
end

return {
    title = "GPS offer: one confirm sets up all, Never is cluster-wide until re-enabled",
    needs = { "net" },
    run = function(sim, H)
        local A = H.serverComputer(pc(1, 0, 70, 0, true))
        local B = H.serverComputer(pc(2, 20, 70, 0))
        local C = H.serverComputer(pc(3, 0, 70, 15))
        local D = H.serverComputer(pc(4, 5, 80, 5))
        local all = { A, B, C, D }
        local mon = A.c.peripherals.top.screen
        sim.run({ maxTime = 80 })
        local function st(S) return S.T.gps.view.st end
        for _, S in ipairs(all) do H.check(st(S) == "offer", "#%d state %s", S.c.id, st(S)) end
        H.check(mon._text():find("GPS possible with 4 PCs", 1, true), "monitor:\n%s", mon._text())

        -- Never on D (a replica): remembered on all, nothing offered or measured afterwards
        H.uiPress(D, "Never")
        sim.run({ maxTime = 8 })
        for _, S in ipairs(all) do
            H.check(S.T.gps.view.never == true and st(S) == "idle", "#%d never=%s st=%s", S.c.id, tostring(S.T.gps.view.never), st(S))
        end
        local t0 = sim.now
        sim.run({ maxTime = 150 })
        H.check(H.sentBy(1, t0, sim.now, "gps_measure") == 0, "measured after Never")
        H.check(not mon._text():find("GPS possible", 1, true), "banner after Never")

        -- GPS page on C: ENABLE turns the offer back on
        local ui = H.uiTerminal(C)
        ui.view = "gps"; C.T.markDirty(); sim.run({ maxTime = 1 })
        H.check(C.c.term._text():find("Off: never", 1, true), "GPS page does not say it is off:\n%s", C.c.term._text())
        H.uiPress(C, "ENABLE")
        sim.run({ maxTime = 40 })
        for _, S in ipairs(all) do H.check(st(S) == "offer" and not S.T.gps.view.never, "#%d st %s after ENABLE", S.c.id, st(S)) end

        -- one confirm (on the replica D's terminal) sets up all
        ui.view = "list"
        local dui = H.uiTerminal(D)
        H.check(D.c.term._text():find("GPS possible with 4 PCs", 1, true), "no banner on #4:\n%s", D.c.term._text())
        H.uiPress(D, "Set up")
        sim.run({ maxTime = 25 })
        for _, S in ipairs(all) do
            H.check(st(S) == "asking", "#%d state %s after the confirm", S.c.id, st(S))
            H.check(not S.c.term._text():find("GPS possible", 1, true) or S.c.term._text():find("GPS setup", 1, true)
                or S.c.term._text():find("GPS: this computer", 1, true), "#%d still shows the offer", S.c.id)
        end
        H.check(not mon._text():find("GPS possible", 1, true) and mon._text():find("GPS setup: waiting for", 1, true),
            "monitor does not show who is asked:\n%s", mon._text())
        local asked = 0
        for _, S in ipairs(all) do
            local a = S.T.gps.view.asks[S.c.id]
            if a then
                asked = asked + 1
                H.check(S.c.term._text():find("Targeted", 1, true), "#%d asked but no prompt:\n%s", S.c.id, S.c.term._text())
            end
        end
        H.check(asked == 3, "%d PCs asked (want 3)", asked)
        return "offer on monitor + 4 terminals; Never cluster-wide then ENABLE; one confirm on a replica -> all in setup, 3 PCs asked"
    end,
}
