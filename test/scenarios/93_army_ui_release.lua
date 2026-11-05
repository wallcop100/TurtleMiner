-- Version: 1.0.0
-- Scenario 93 (army UI): RELEASE of a claimed branch held by a silent turtle, keyboard only, with the
-- confirmation. The branch is free again, the turtle's lane is freed, and a live turtle is not listed.
local BASIC = { { side = "back", kind = "basic" } }
return {
    title = "army UI: release a silent turtle's claim",
    needs = { "net" },
    run = function(sim, H)
        local S = H.serverComputer({ id = 5, basic = true, pos = { x = 0, y = 70, z = 0 }, modems = BASIC, termSize = { 26, 20 } })
        sim.run({ maxTime = 25 })
        local T = S.T
        local K = S.c.env.keys
        local kb
        for _, u in ipairs(T.S.uis) do if u.side == nil then kb = u end end
        local now = T.now()
        local a = T.army.new("gamma", { x = 0, y = 64, z = 0, f = 0 }, { "diamond" }, nil, now)
        for _, id in ipairs({ 21, 22 }) do
            a.members[id] = { joined = now, state = "work" }
        end
        a.branches["-58:0:0:R"] = { state = "claimed", tid = 21, since = now - 600000 }
        a.branches["-58:0:0:L"] = { state = "claimed", tid = 22, since = now }
        a.segs["s1:0"] = { dir = "down", holders = { [21] = now - 600000 } }
        T.S.turtles[21] = { id = 21, lastSeen = now - 900000, alert = "SILENT", events = {}, st = {} }
        T.S.turtles[22] = { id = 22, lastSeen = now, events = {}, st = {} }
        local function press(k) sim.key(S.c, k); sim.run({ maxTime = 0.1 }) end
        local function activate(match)
            for _ = 1, 60 do
                local b = kb.focus and kb.buttons[kb.focus]
                if b and b.key:find(match, 1, true) then press(K.enter); return end
                press(K.tab)
            end
            H.fail("no button %q:\n%s", match, S.c.term._text())
        end
        kb.view = "armies"; T.render(kb)
        activate("gamma")
        H.check(kb.view == "army", "view %s", kb.view)
        activate("SET")
        activate("RELEASE")
        H.check(kb.view == "armyrel", "view %s", kb.view)
        local txt = S.c.term._text()
        H.check(txt:find("#21", 1, true) and not txt:find("#22", 1, true), "silent list wrong:\n%s", txt)
        activate("#21")
        H.check(kb.view == "armyrelok", "view %s", kb.view)
        activate("NO")
        H.check(a.branches["-58:0:0:R"], "NO released the claim")
        activate("#21")
        activate("YES FREE")
        H.check(not a.branches["-58:0:0:R"] and a.branches["-58:0:0:L"], "release did the wrong thing")
        H.check(not a.segs["s1:0"], "segment not freed")
        H.check(#S.c.term._violations == 0, "writes off screen")
        return "released"
    end,
}
