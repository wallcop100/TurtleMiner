-- Version: 1.0.0
-- Scenario 92 (army UI): map / traffic / stats / settings render a fake army record at 26x20, 39x13,
-- 51x19 and 164x81 without writing off screen, and show the expected content.
local BASIC = { { side = "back", kind = "basic" } }
local SIZES = { { 26, 20 }, { 39, 13 }, { 51, 19 }, { 164, 81 } }

local function fake(now)
    local a = { name = "beta", station = { x = 0, y = 64, z = 0, f = 2 },
        levels = { { y = -58, focus = { "diamond", "redstone" } }, { y = 16, focus = { "iron" } } },
        geom = { bl = 32, sp = 3, ml = 64 }, settings = { FOCUS = "all" },
        shafts = { { k = 1, done = true }, { k = 2, done = true } }, members = {}, branches = {}, extra = { ["1,2,3"] = now },
        segs = { ["s1:0"] = { dir = "down", holders = { [11] = now, [12] = now } }, ["s1:1"] = { dir = "down", holders = { [11] = now } },
            ["sp-58:0"] = { dir = "out", holders = { [13] = now } } },
        slots = { { tid = 14, shaft = 2, dir = "up", at = now + 120000, len = 60000 } }, queue = { 15, 16 },
        stats = { ores = { diamond = 12, iron = 40 }, branchesDone = 30, startedAt = now - 7200000, fuelUsed = 5000 },
        paused = false, wait = { avgMs = 30000, n = 4 }, waiting = {} }
    for tid = 11, 16 do a.members[tid] = { joined = now, state = "work" } end
    local n = 0
    for c = -2, 2 do
        for b = 0, 9 do
            for _, y in ipairs({ -58, 16 }) do
                for _, side in ipairs({ "R", "L" }) do
                    n = n + 1
                    local key = y .. ":" .. c .. ":" .. b .. ":" .. side
                    if n % 3 == 0 then a.branches[key] = { state = "done", step = 32, since = now }
                    elseif n % 7 == 0 then a.branches[key] = { state = "claimed", tid = 11 + n % 6, since = now } end
                end
            end
        end
    end
    return a
end

return {
    title = "army UI: map, traffic, stats, settings at 4 sizes without off-screen writes",
    needs = { "net" },
    run = function(sim, H)
        for i, wh in ipairs(SIZES) do
            local w, h = wh[1], wh[2]
            local S = H.serverComputer({ id = 4 + i, basic = true, pos = { x = 0, y = 70, z = 0 }, modems = BASIC, termSize = { w, h } })
            sim.run({ maxTime = 25 })
            local T = S.T
            local kb
            for _, u in ipairs(T.S.uis) do if u.side == nil then kb = u end end
            local now = T.now()
            T.S.armies.beta = fake(now)
            for tid = 11, 16 do
                T.S.turtles[tid] = { id = tid, lastSeen = now, events = {}, st = { phase = "MINING", facing = tid % 4,
                    pos = { x = (tid - 13) * 3, y = (tid % 2 == 0) and -58 or 16, z = 20 + tid } } }
            end
            local function show(tab, want)
                kb.view, kb.army = "army", { name = "beta", tab = tab, lvl = 1, ox = 0, oy = 0, scr = 0 }
                T.render(kb)
                local txt = S.c.term._text()
                if want then H.check(txt:find(want, 1, true), "%dx%d %s: missing %q:\n%s", w, h, tab, want, txt) end
                return txt
            end
            local txt = show("map", "Y-58")
            H.check(txt:find("#", 1, true) and txt:find("+", 1, true) and txt:find(".", 1, true), "%dx%d map has no cells:\n%s", w, h, txt)
            H.check(txt:find("S", 1, true), "no shaft")
            kb.army.lvl = 2; T.render(kb)
            H.check(S.c.term._text():find("Y16", 1, true), "level 2 not shown")
            kb.army.z = 2; kb.army.ox = 3; kb.army.oy = -1; T.render(kb)
            kb.army.ox, kb.army.oy = 9999, 9999; T.render(kb)
            show("traf", nil)
            if h >= 13 then show("traf", "s1:0") end
            show("stats", nil)
            if h >= 19 then show("stats", "Ores per hour") end
            show("set", nil)
            for _, v in ipairs({ "armies", "armyrel" }) do
                kb.view = v; T.render(kb)
            end
            kb.army.tab = "set"; kb.view = "armynum"; kb.army.num = { prompt = "Y", lo = -64, hi = 63, ok = function() end }; kb.input = "-5"
            T.render(kb)
            kb.view = "armywiz"; kb.wz = { step = 1, ores = {}, name = "" }
            for st = 1, 7 do
                kb.wz.step, kb.wz.x, kb.wz.y, kb.wz.z, kb.wz.f, kb.wz.name = st, 1, 64, -3, 1, "q"
                kb.wz.ores = { diamond = true }
                T.render(kb)
            end
            local v = S.c.term._violations
            H.check(#v == 0, "%dx%d: %d writes off screen, first at (%d,%d) %q", w, h, #v, v[1] and v[1].x or 0, v[1] and v[1].y or 0, v[1] and v[1].text or "")
            S.kill()
        end
        return "4 sizes ok"
    end,
}
