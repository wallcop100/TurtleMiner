-- Version: 1.0.0
-- Scenario 49 (COMMS.md hardware rules): a BASIC computer (no colour, no mouse, no
-- multishell) with a BASIC monitor (greyscale, never sends monitor_touch) runs tminer_server.
-- The whole UI is driven from the keyboard (Tab/arrows + Enter, Backspace = back, typed
-- digits): list -> turtle card -> PAUSE, TARGET_Y -40, focus ore, SET a yes/no key, RESET
-- HOME with its confirmation, event log. The monitor follows the keyboard (same screen).
-- Every write stays on screen (terminal and monitor), only greyscale colours are used, and
-- each command reaches the turtle once.
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }
local GREY = { ["0"] = true, ["7"] = true, ["8"] = true, ["f"] = true }   -- white, gray, lightGray, black

local function greyOnly(term, h)
    for y = 1, h do
        local _, fg, bg = term.getLine(y)
        for i = 1, #fg do
            if not GREY[fg:sub(i, i)] or not GREY[bg:sub(i, i)] then return false, y end
        end
    end
    return true
end

return {
    title = "keyboard-only UI on a basic PC with a basic monitor",
    needs = { "net" },
    run = function(sim, H)
        local w = sim.world()
        local S = H.serverComputer({ id = 5, basic = true, pos = { x = 0, y = 70, z = 0 },
            modems = { { side = "back", kind = "basic" } }, monitor = { side = "top", w = 29, h = 12, color = false } })
        local t = sim.turtle(w, { id = 1, pos = { x = 10, y = 60, z = 0 }, equip = BASIC })
        local tc = H.netTurtle(t, "Digger")
        sim.run({ maxTime = 25 })
        H.check(S.role() == "leader", "server role %s", S.role())
        H.check(S.c.env.multishell == nil, "a basic computer has multishell in the sim")
        H.check(sim.touch(S.c, "top", 3, 3) == false, "basic monitor accepted a touch")
        H.check(sim.click(S.c, 3, 3) == false, "basic computer accepted a mouse click")
        local mon = S.c.peripherals.top.screen
        local kb, mui
        for _, u in ipairs(S.T.S.uis) do
            if u.side == nil then kb = u else mui = u end
        end
        H.check(kb and mui and mui.follow and not mui.color and not kb.color, "UIs: terminal %s, monitor %s (follow %s)",
            tostring(kb), tostring(mui), tostring(mui and mui.follow))
        local K = S.c.env.keys
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
        local function both(view, text)
            H.check(kb.view == view and mui.view == view, "views: terminal %s, monitor %s (want %s)", kb.view, mui.view, view)
            if text then
                H.check(mon._text():find(text, 1, true), "monitor does not show %q:\n%s", text, mon._text())
                H.check(S.c.term._text():find(text, 1, true), "terminal does not show %q:\n%s", text, S.c.term._text())
            end
        end
        local steps = 0
        local function done(cmd, key, n)
            sim.run({ maxTime = 3 })
            H.check(H.appliedCount(tc, cmd, key) == (n or 1), "%s %s applied %d times", cmd, tostring(key),
                H.appliedCount(tc, cmd, key))
            steps = steps + 1
        end
        both("list", "Digger")
        activate("#1");            both("detail", "Digger #1")
        H.check(mon._text():find(">", 1, true), "monitor shows no focus marker:\n%s", mon._text())
        activate("PAUSE");         done("PAUSE")
        activate("TARGET Y");      both("num", "TARGET_Y")
        type_("40"); press(K.minus); type_("-")  -- digits, then '-' typed as a character flips the sign
        H.check(kb.input == "-40", "typed value %q", kb.input)
        press(K.enter);            done("SET", "TARGET_Y")
        local applied = tc.applied[#tc.applied]
        H.check(applied.params.value == -40, "TARGET_Y sent as %s", tostring(applied.params.value))
        activate("FOCUS ORE");     both("focus", "Focus ore #1")
        activate("diamond");       done("SET", "FOCUS")
        activate("SET...");        both("keys", "DROP_TRASH")
        activate("DROP_TRASH");    both("bool", "DROP_TRASH")
        activate("FALSE");         done("SET", "DROP_TRASH")
        activate("RESET HOME");    both("confirm", "Reset home?")
        press(K.backspace);        both("detail")
        H.check(H.appliedCount(tc, "RESET_HOME") == 0, "RESET_HOME sent without YES")
        activate("RESET HOME");    activate("YES RESET"); done("RESET_HOME")
        press(K.backspace);        both("list")
        activate("LOG");           both("log", "Event log")
        press(K.backspace);        both("list")
        -- bounds and colours
        local vt, vm = S.c.term._violations, mon._violations
        H.check(#vt == 0, "%d writes off the terminal, first at (%d,%d)", #vt, vt[1] and vt[1].x or 0, vt[1] and vt[1].y or 0)
        H.check(#vm == 0, "%d writes off the monitor, first at (%d,%d)", #vm, vm[1] and vm[1].x or 0, vm[1] and vm[1].y or 0)
        local okT, yT = greyOnly(S.c.term, 19)
        local okM, yM = greyOnly(mon, 12)
        H.check(okT and okM, "colour used on a basic screen (terminal row %s, monitor row %s)", tostring(yT), tostring(yM))
        -- every view rendered on the basic monitor at a few sizes: nothing off screen
        local fuzz = 0
        for _, wh in ipairs({ { 7, 5 }, { 15, 10 }, { 29, 12 }, { 39, 19 }, { 61, 26 } }) do
            local scr = sim.Term.new(wh[1], wh[2], { strict = true, color = false })
            local u = S.T.newUI(scr, "x")
            for _, v in ipairs({ "list", "detail", "cmds", "num", "focus", "keys", "bool", "confirm", "text", "log" }) do
                u.view, u.sel, u.setKey, u.input, u.text, u.focus = v, 1, "TARGET_Y", "-12", "x", 2
                S.T.render(u)
                fuzz = fuzz + 1
            end
            H.check(#scr._violations == 0, "%dx%d basic screen: %d writes off screen", wh[1], wh[2], #scr._violations)
        end
        H.check(S.c.alive, "server stopped: %s", tostring(S.c.err))
        return string.format("%d commands sent by keyboard only, monitor followed every screen; 0 writes off screen; greyscale only; %d fuzz renders",
            steps, fuzz)
    end,
}
