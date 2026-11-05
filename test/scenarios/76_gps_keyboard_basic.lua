-- Version: 1.0.0
-- Scenario 76 (COMMS.md hardware rules + CG-3/CG-4): BASIC computers (no colour, no mouse) and a
-- BASIC monitor (greyscale, no touch). The whole GPS flow by keyboard only: the offer banner
-- (Tab to Set up, Enter), the coordinate prompts typed on each asked PC's own terminal, the
-- GPS page and the cluster page opened through NET with Tab/Enter. The monitor follows the
-- keyboard; every screen stays inside its bounds, in greyscale, at several sizes.
local GREY = { ["0"] = true, ["7"] = true, ["8"] = true, ["f"] = true }

local function greyOnly(term, h)
    for y = 1, h do
        local _, fg, bg = term.getLine(y)
        for i = 1, #fg do
            if not GREY[fg:sub(i, i)] or not GREY[bg:sub(i, i)] then return false, y end
        end
    end
    return true
end

local function pc(id, x, y, z, mon)
    local o = { id = id, basic = true, pos = { x = x, y = y, z = z }, modems = { { side = "back", kind = "basic" } } }
    if mon then o.monitor = { side = "top", w = 29, h = 12, color = false } end
    return o
end

return {
    title = "GPS flow by keyboard only on basic PCs with a basic monitor",
    needs = { "net" },
    run = function(sim, H)
        local spec = { pc(1, 0, 70, 0, true), pc(2, 20, 70, 0), pc(3, 0, 70, 15), pc(4, 5, 80, 5) }
        local all, byId = {}, {}
        for _, o in ipairs(spec) do local S = H.serverComputer(o); all[#all + 1] = S; byId[o.id] = S end
        local A = all[1]
        local mon = A.c.peripherals.top.screen
        H.check(sim.touch(A.c, "top", 3, 3) == false and sim.click(A.c, 3, 3) == false, "basic hardware accepted touch/mouse")
        sim.run({ maxTime = 80 })
        H.check(A.T.gps.view.st == "offer", "state %s", A.T.gps.view.st)
        H.check(mon._text():find("GPS possible with 4 PCs", 1, true), "basic monitor shows no offer:\n%s", mon._text())
        H.check(A.c.term._text():find("Set up", 1, true), "terminal shows no Set up button:\n%s", A.c.term._text())

        -- GPS page and cluster page by keyboard (NET -> GPS / CLUSTER), Backspace goes back
        local ui = H.uiPress(A, "NET")
        H.check(ui.view == "net", "view %s", ui.view)
        H.uiPress(A, "GPS")
        H.check(ui.view == "gps" and A.c.term._text():find("Possible with 4 PCs", 1, true), "GPS page:\n%s", A.c.term._text())
        sim.key(A.c, A.c.env.keys.backspace); sim.run({ maxTime = 0.3 })
        H.check(ui.view == "net", "Backspace from the GPS page: %s", ui.view)
        H.uiPress(A, "CLUSTER")
        H.check(ui.view == "cluster" and A.c.term._text():find("Leader: #1", 1, true), "cluster page:\n%s", A.c.term._text())
        sim.key(A.c, A.c.env.keys.backspace); sim.run({ maxTime = 0.3 })
        sim.key(A.c, A.c.env.keys.backspace); sim.run({ maxTime = 0.3 })
        H.check(ui.view == "list", "back to the list: %s", ui.view)

        -- Set up with the keyboard on the leader; prompts on the asked PCs' terminals
        H.uiPress(A, "Set up")
        sim.run({ maxTime = 12 })
        H.check(A.T.gps.view.st == "asking", "state %s", A.T.gps.view.st)
        local order = {}
        for id in pairs(A.T.gps.view.asks) do order[#order + 1] = id end
        table.sort(order)
        H.check(#order == 3, "%d asked", #order)
        for _, id in ipairs(order) do
            local S = byId[id]
            H.check(S.c.term._text():find("Targeted", 1, true), "#%d has no prompt", id)
            H.check(H.uiTerminal(S).view == "gpsask", "#%d view %s", id, H.uiTerminal(S).view)
            local p = S.c.pos
            H.uiType(S, string.format("%d %d %d", p.x, p.y, p.z))
        end
        sim.run({ maxTime = 2 })
        local aid, a
        for id, v in pairs(A.T.gps.view.asks) do aid, a = id, v end
        H.check(a and a.kind == "axis", "no axis question")
        local S = byId[aid]
        H.uiType(S, tostring(S.c.pos[a.axis]))
        sim.run({ maxTime = 4 })
        for _, S2 in ipairs(all) do
            local h = S2.T.gps.view.hosts[S2.c.id]
            local p = S2.c.pos
            H.check(S2.T.gps.view.st == "on" and h and h.x == p.x and h.y == p.y and h.z == p.z, "#%d state %s", S2.c.id, S2.T.gps.view.st)
        end

        -- bounds and colours: terminal + monitor, then every GPS view at several sizes
        local vt, vm = A.c.term._violations, mon._violations
        H.check(#vt == 0 and #vm == 0, "writes off screen: terminal %d, monitor %d", #vt, #vm)
        local okT = greyOnly(A.c.term, 19)
        local okM = greyOnly(mon, 12)
        H.check(okT and okM, "colour used on a basic screen")
        local fuzz = 0
        for _, wh in ipairs({ { 7, 5 }, { 15, 10 }, { 29, 12 }, { 39, 19 }, { 61, 26 } }) do
            local scr = sim.Term.new(wh[1], wh[2], { strict = true, color = false })
            local u = A.T.newUI(scr, "x")
            for _, v in ipairs({ "list", "net", "gps", "cluster", "gpsask" }) do
                u.view, u.input = v, "12 70 -3"
                A.T.render(u)
                fuzz = fuzz + 1
            end
            H.check(#scr._violations == 0, "%dx%d basic screen: %d writes off screen", wh[1], wh[2], #scr._violations)
        end
        return string.format("keyboard-only offer, pages and prompts on basic PCs + monitor; greyscale, 0 writes off screen, %d fuzz renders", fuzz)
    end,
}
