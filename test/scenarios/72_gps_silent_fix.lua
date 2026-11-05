-- Version: 1.0.0
-- Scenario 72 (CG-3): silent setup. Four of five PCs already get a GPS fix (another
-- constellation in reach, answered over the raw modem channel); the fifth is out of reach of it.
-- After ONE confirm nobody is asked anything: the four fixes anchor the measured layout and the
-- fifth PC's position is worked out from its measured distances. Every host announces exactly
-- the computer block it stands on (the point a wireless modem measures from).
local function pc(id, x, y, z, mon)
    local o = { id = id, pos = { x = x, y = y, z = z }, modems = { { side = "back", kind = "basic" } } }
    if mon then o.monitor = { side = "top", w = 39, h = 14 } end
    return o
end

return {
    title = "GPS silent setup from PCs that already have a fix, no prompts",
    needs = { "net" },
    run = function(sim, H)
        H.rawGps({
            { pos = { x = 40, y = 70, z = 0 } }, { pos = { x = 35, y = 80, z = 25 } },
            { pos = { x = 30, y = 60, z = -25 } }, { pos = { x = 35, y = 75, z = 10 } },
        })
        local spec = { pc(1, 0, 70, 0, true), pc(2, 20, 70, 0), pc(3, 0, 70, 15), pc(4, 5, 80, 5), pc(5, -25, 70, 0) }
        local all = {}
        for _, o in ipairs(spec) do all[#all + 1] = H.serverComputer(o) end
        local A = all[1]
        sim.run({ maxTime = 80 })
        H.check(A.T.gps.view.st == "offer", "state %s", A.T.gps.view.st)
        H.uiPress(A, "Set up")
        local asked = false
        for _ = 1, 40 do
            sim.run({ maxTime = 1 })
            for _, S in ipairs(all) do if next(S.T.gps.view.asks) or S.c.term._text():find("Targeted", 1, true) then asked = true end end
        end
        H.check(not asked, "a PC was asked for coordinates")
        for _, S in ipairs(all) do
            H.check(S.T.gps.view.st == "on", "#%d state %s (%s)", S.c.id, S.T.gps.view.st, tostring(S.T.gps.view.note))
            local h = S.T.gps.view.hosts[S.c.id]
            local p = S.c.pos
            H.check(h and h.st == "hosting" and h.x == p.x and h.y == p.y and h.z == p.z, "#%d hosts as %s,%s,%s (real %d,%d,%d)",
                S.c.id, tostring(h and h.x), tostring(h and h.y), tostring(h and h.z), p.x, p.y, p.z)
            H.check(S.T.gps.wanted(), "#%d is not answering pings", S.c.id)
        end
        H.check(A.logText():find("constellation up with 5 hosts", 1, true), "no log line")
        local gpsPage = H.uiTerminal(A)
        gpsPage.view = "gps"; A.T.markDirty(); sim.run({ maxTime = 1 })
        local txt = A.c.term._text()
        H.check(txt:find("ON: 5 hosts", 1, true) and txt:find("Reach:", 1, true), "GPS page:\n%s", txt)
        return "5 PCs, 4 with a fix: one confirm, no prompts, every host announces its own block; GPS page shows hosts + reach"
    end,
}
