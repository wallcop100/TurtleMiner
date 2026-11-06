-- Version: 1.0.0
-- Scenario 91 (army UI): on a basic PC + basic monitor the New-army wizard is driven from the keyboard
-- only (NET > ARMY > NEW: name, X Y Z with a negative number, facing, ore presets, CREATE). The
-- army_new body reaches the coordinator and the army exists with the expected levels.
local BASIC = { { side = "back", kind = "basic" } }
return {
    title = "army UI: wizard by keyboard creates an army",
    needs = { "net" },
    run = function(sim, H)
        local S = H.serverComputer({ id = 5, basic = true, pos = { x = 0, y = 70, z = 0 }, modems = BASIC,
            monitor = { side = "top", w = 39, h = 13, color = false } })
        sim.run({ maxTime = 25 })
        H.check(S.role() == "leader", "role %s", S.role())
        local T = S.T
        H.check(T.VIEWS.armies, "tm_army_ui not loaded")
        local sent = {}
        local orig = T.army.handle
        T.army.handle = function(msg, now) sent[#sent + 1] = msg; return orig(msg, now) end
        local K = S.c.env.keys
        local kb, mui
        for _, u in ipairs(T.S.uis) do if u.side == nil then kb = u else mui = u end end
        local function press(k) sim.key(S.c, k); sim.run({ maxTime = 0.1 }) end
        local function type_(s) for ch in s:gmatch(".") do sim.char(S.c, ch); sim.run({ maxTime = 0.1 }) end end
        local function activate(label)
            for _ = 1, 80 do
                local b = kb.focus and kb.buttons[kb.focus]
                if b and b.key == label then press(K.enter); return end
                press(K.tab)
            end
            H.fail("no button %q:\n%s", label, S.c.term._text())
        end
        activate("NET");  H.check(kb.view == "net", "view %s", kb.view)
        activate("ARMY"); H.check(kb.view == "armies", "view %s", kb.view)
        activate("NEW");  H.check(kb.view == "armywiz", "view %s", kb.view)
        type_("alpha"); press(K.enter)
        type_("100"); press(K.enter)                  -- X
        type_("64"); press(K.enter)                   -- Y
        type_("-"); type_("250"); press(K.enter)      -- Z = -250
        H.check(kb.wz and kb.wz.z == -250 and kb.wz.step == 5, "wizard state z=%s step=%s", tostring(kb.wz and kb.wz.z),
            tostring(kb.wz and kb.wz.step))
        type_("e")                                    -- facing east
        type_("1"); type_("2"); type_("4")            -- diamond, redstone, gold
        H.check(S.c.term._text():find("-58", 1, true), "levels not shown:\n%s", S.c.term._text())
        press(K.enter)                                -- to the summary
        H.check(mui.view == "armywiz" and mui.wz.step == 7, "monitor does not follow the wizard")
        press(K.enter)                                -- create
        local m
        for _, x in ipairs(sent) do if x.kind == "army_new" then m = x end end
        H.check(m, "no army_new sent")
        H.check(m.name == "alpha" and m.station.x == 100 and m.station.y == 64 and m.station.z == -250 and m.station.f == 1,
            "army_new station wrong")
        H.check(#m.ores == 3 and m.ores[1] == "diamond", "army_new ores wrong")
        local a = T.S.armies.alpha
        H.check(a and #a.levels == 2 and a.levels[1].y == -58 and a.levels[2].y == -16, "army record wrong")
        H.check(kb.view == "army", "view after create: %s", kb.view)
        press(K.right); press(K.pageDown); type_("2")
        H.check(kb.army.tab == "traf", "tab key")
        H.check(#S.c.term._violations == 0 and #S.c.peripherals.top.screen._violations == 0, "writes off screen")
        return "wizard created army alpha"
    end,
}
