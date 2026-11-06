-- Version: 1.0.0
-- Scenario 96 (army on a replica PC): a non-leader server PC creates an army (forwarded to the
-- leader, replicated back), releases a silent turtle's claim through the keyboard UI, and extra
-- digs a member turtle reports in `catchup` / `status` land in the army record.
local BASIC = { { side = "back", kind = "basic" } }
return {
    title = "army: actions from a replica PC; extra digs reach the army",
    needs = { "net" },
    run = function(sim, H)
        local wired = { side = "back", kind = "wired", net = "base" }
        local A = H.serverComputer({ id = 10, modems = { wired } })
        local B = H.serverComputer({ id = 11, pos = { x = 0, y = 70, z = 0 }, termSize = { 26, 20 },
            modems = { wired, { side = "top", kind = "basic" } } })
        sim.run({ maxTime = 30 })
        H.check(A.role() == "leader" and B.role() == "replica", "roles %s %s", A.role(), B.role())
        local TB, TA = B.T, A.T
        local K = B.c.env.keys
        local kb
        for _, u in ipairs(TB.S.uis) do if u.side == nil then kb = u end end
        H.check(kb, "no keyboard ui on replica")
        local a, err = (function()
            return TB.forwardArmy({ kind = "army_new", from = 11, name = "delta",
                station = { x = 0, y = 64, z = 0, f = 0 }, ores = { "diamond" } })
        end)()
        H.check(a, "forward refused: %s", tostring(err))
        sim.run({ maxTime = 12 })
        local army = TA.S.armies.delta
        H.check(army, "leader has no army")
        H.check(TB.S.armies.delta, "army not replicated to the replica")
        local now = TA.now()
        army.members[21] = { joined = now, state = "work" }
        army.branches["-58:0:0:R"] = { state = "claimed", tid = 21, since = now - 600000 }
        TA.S.turtles[21] = { id = 21, lastSeen = now - 900000, alert = "SILENT", events = {}, st = {} }
        TA.S.dA.delta = true
        TA.markDirty()
        sim.run({ maxTime = 12 })
        TB.S.turtles[21] = TB.S.turtles[21] or { id = 21, lastSeen = now - 900000, alert = "SILENT", events = {}, st = {} }
        TB.S.turtles[21].alert, TB.S.turtles[21].lastSeen = "SILENT", now - 900000
        H.check(TB.S.armies.delta.branches["-58:0:0:R"], "claim not replicated")

        local function press(k) sim.key(B.c, k); sim.run({ maxTime = 0.1 }) end
        local function activate(match)
            for _ = 1, 60 do
                local b = kb.focus and kb.buttons[kb.focus]
                if b and b.key:find(match, 1, true) then press(K.enter); return end
                press(K.tab)
            end
            H.fail("no button %q:\n%s", match, B.c.term._text())
        end
        kb.view = "armies"; TB.render(kb)
        activate("delta"); activate("SET"); activate("RELEASE"); activate("#21"); activate("YES FREE")
        sim.run({ maxTime = 12 })
        H.check(not TA.S.armies.delta.branches["-58:0:0:R"], "release did not reach the leader")

        -- extra digs from a member: catchup and status
        local function turtleMsg(kind, extra)
            TA.handleMessage(21, H.sign({ v = 1, kind = kind, from = 21, boot = 1, seq = extra[1] == "5,-58,5" and 1 or 2,
                extra = extra, events = {}, ts = H.epochMs(), hops = 0 }), "TMINER")
        end
        turtleMsg("catchup", { "5,-58,5", "6,-58,5", "bad" })
        turtleMsg("status", { "7,-58,5" })
        local e = TA.S.armies.delta.extra
        H.check(e["5,-58,5"] and e["6,-58,5"] and e["7,-58,5"] and not e.bad, "extra digs missing")
        return "replica army ok"
    end,
}
