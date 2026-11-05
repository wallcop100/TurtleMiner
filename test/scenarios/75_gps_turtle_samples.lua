-- Version: 1.0.0
-- Scenario 75 (CG-3b): a turtle that knows its world position walks around near the PCs. Its
-- net.lua records the raw-modem distance to every server PC it hears directly and sends them
-- (gps_sample). The leader anchors the measured layout from those samples: ONE confirm, no
-- prompts. Then the same turtle gets exact fixes from the result through the real raw
-- gps.locate exchange (PING on the GPS channel, hosts answer, trilateration).
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }
local function pc(id, x, y, z, mon)
    local o = { id = id, pos = { x = x, y = y, z = z }, modems = { { side = "back", kind = "basic" } } }
    if mon then o.monitor = { side = "top", w = 39, h = 14 } end
    return o
end

return {
    title = "GPS anchored from turtle samples (no prompts); a turtle then gets correct fixes",
    needs = { "net" },
    run = function(sim, H)
        H.rawGps({})                                  -- raw gps.locate in the sim, no outside GPS
        local w = sim.world()
        local spec = { pc(1, 0, 70, 0, true), pc(2, 20, 70, 0), pc(3, 0, 70, 15), pc(4, 5, 80, 5) }
        local all = {}
        for _, o in ipairs(spec) do all[#all + 1] = H.serverComputer(o) end
        local A = all[1]
        local t = sim.turtle(w, { id = 9, pos = { x = 10, y = 60, z = 5 }, equip = BASIC })
        local tc = H.netTurtle(t, "Scout")
        sim.run({ maxTime = 2 })
        tc.net.setGpsPos(function() return { x = t.pos.x, y = t.pos.y, z = t.pos.z } end)

        -- no GPS yet: a locate finds nothing
        tc.jobs[#tc.jobs + 1] = function(net, G) local x = G.gps.locate(2); return x and "fix" or "none" end
        sim.run({ maxTime = 4 })
        H.check(tc.results[1] == "none", "fix before any host: %s", tostring(tc.results[1]))

        local walk = { { 12, 75, 3 }, { -8, 66, 10 }, { 15, 90, -6 }, { 3, 55, 20 }, { -5, 80, -10 }, { 22, 68, 18 }, { 8, 62, -12 } }
        for _, p in ipairs(walk) do
            t.pos.x, t.pos.y, t.pos.z = p[1], p[2], p[3]
            sim.run({ maxTime = 9 })
        end
        sim.run({ maxTime = 60 })
        local n = 0
        for _, l in pairs(A.T.gps.view and A.T.gps.view.hosts or {}) do n = n + 1 end
        H.check(A.T.gps.view.st == "offer", "no offer: %s (%s)", A.T.gps.view.st, tostring(A.T.gps.view.note))
        H.uiPress(A, "Set up")
        local asked = false
        for _ = 1, 25 do
            sim.run({ maxTime = 1 })
            for _, S in ipairs(all) do if next(S.T.gps.view.asks) then asked = true end end
        end
        local cnt = {}
        for id, l in pairs(A.T.gps.samples) do cnt[#cnt + 1] = id .. ":" .. #l end
        H.check(not asked, "PCs were asked although turtle samples anchor the layout (samples %s)", table.concat(cnt, " "))
        for _, S in ipairs(all) do
            local h = S.T.gps.view.hosts[S.c.id]
            local p = S.c.pos
            H.check(S.T.gps.view.st == "on" and h and h.x == p.x and h.y == p.y and h.z == p.z, "#%d hosts as %s (real %d,%d,%d), state %s",
                S.c.id, h and (h.x .. "," .. h.y .. "," .. h.z) or "-", p.x, p.y, p.z, S.T.gps.view.st)
        end

        -- the turtle at three new places gets exact fixes from the new constellation
        local spots = { { 30, 64, 9 }, { -12, 85, 5 }, { 6, 58, -20 } }
        for i, p in ipairs(spots) do
            t.pos.x, t.pos.y, t.pos.z = p[1], p[2], p[3]
            tc.jobs[#tc.jobs + 1] = function(net, G)
                local x, y, z = G.gps.locate(2)
                return x and string.format("%d,%d,%d", x, y, z) or "none"
            end
            sim.run({ maxTime = 4 })
            local want = string.format("%d,%d,%d", p[1], p[2], p[3])
            H.check(tc.results[1 + i] == want, "fix %d: got %s, want %s", i, tostring(tc.results[1 + i]), want)
        end
        return "samples from a walking turtle anchored 4 PCs with no prompt; the turtle then got 3/3 exact fixes via raw gps.locate"
    end,
}
