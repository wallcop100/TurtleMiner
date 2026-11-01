-- Version: 1.0.0
-- Scenario 47 (CG-1/CG-2): three server PCs act as ONE server.
--   #10 wired-only (lowest ID: the leader), #11 wired + basic wireless (radio gateway),
--   #12 wired-only. All run the same tminer_server; roles are detected from peripherals.
--   A basic-modem turtle 45 blocks from the gateway (out of reach of nothing else) is managed:
--   exactly one leader, every PC knows the turtle, only the leader sends `fleet`, answers
--   `home_get` (one reply) and transmits commands; a command typed on #12's keyboard (a
--   wired-only PC) reaches the turtle through the leader and the gateway, applied once.
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }

return {
    title = "cluster: 1 wireless + 2 wired-only PCs act as one server",
    needs = { "net" },
    run = function(sim, H)
        local w = sim.world()
        local wired = { side = "back", kind = "wired", net = "base" }
        local A = H.serverComputer({ id = 10, modems = { wired } })
        local G = H.serverComputer({ id = 11, pos = { x = 0, y = 70, z = 0 },
            modems = { wired, { side = "top", kind = "basic" } } })
        local B = H.serverComputer({ id = 12, modems = { wired } })
        local all = { A, G, B }
        local t = sim.turtle(w, { id = 1, pos = { x = 40, y = 50, z = 0 }, equip = BASIC })
        local tc = H.netTurtle(t)
        sim.run({ maxTime = 30 })

        -- roles detected per PC
        H.check(G.T.roles.gateway and G.T.roles.link, "gateway roles: %s", G.T.rolesText())
        H.check(A.T.roles.link and not A.T.roles.gateway, "#10 roles: %s", A.T.rolesText())
        -- one leader, the lowest ID; the others replicate it
        local leaders = {}
        for _, s in ipairs(all) do if s.role() == "leader" then leaders[#leaders + 1] = s.c.id end end
        H.check(#leaders == 1 and leaders[1] == 10, "leaders: %s", table.concat(leaders, ","))
        for _, s in ipairs({ G, B }) do
            H.check(s.role() == "replica" and s.T.C.leader == 10, "#%d is %s of %s", s.c.id, s.role(), tostring(s.T.C.leader))
        end
        -- the turtle: in contact through the gateway (hop 1), known on every PC
        H.check(tc.net.inContact() and tc.net.hop() == 1, "turtle contact %s hop %s", tostring(tc.net.inContact()),
            tostring(tc.net.hop()))
        local nowMs = function() return sim.BASE_EPOCH + sim.now * 1000 end
        for _, s in ipairs(all) do
            local r = s.rec(1)
            H.check(r and nowMs() - r.lastSeen < 16000, "#%d does not know the turtle (replication)", s.c.id)
        end
        -- home record: saved once, one answer from the leader only
        local t0 = sim.now
        tc.jobs[#tc.jobs + 1] = function(net)
            net.send("home_save", "server", { home = { x = 40, y = 50, z = 0 }, homeFacing = 2, gps = false })
            return true
        end
        sim.run({ maxTime = 3 })
        tc.jobs[#tc.jobs + 1] = function(net) return net.request("home_get", {}, "home", 3) end
        sim.run({ maxTime = 8 })
        local reply = tc.results[2]
        H.check(type(reply) == "table" and reply.found == true and reply.home.z == 0 and reply.homeFacing == 2,
            "home_get answer: %s", sim.textutils.serialize(reply))
        local homes, nHome = H.originals("home", t0)
        H.check(nHome == 1 and homes[10] == 1, "home replies: %d (want 1, from the leader)", nHome)
        for _, s in ipairs(all) do
            H.check(s.T.S.homes[1] and s.T.S.homes[1].homeFacing == 2, "#%d has no copy of the home record", s.c.id)
        end
        -- a command from the wired-only PC's keyboard: list -> turtle card -> PAUSE
        local K = B.c.env.keys
        local ui
        for _, u in ipairs(B.T.S.uis) do if u.side == nil then ui = u end end
        H.check(ui ~= nil, "#12 has no terminal UI")
        local function press(k) sim.key(B.c, k); sim.run({ maxTime = 0.1 }) end
        local function activate(label)
            for _ = 1, 80 do
                local b = ui.focus and ui.buttons[ui.focus]
                if b and b.key == label then press(K.enter); return end
                press(K.tab)
            end
            H.fail("no button %q on #12:\n%s", label, B.c.term._text())
        end
        local tCmd = sim.now
        activate("#1")
        H.check(ui.view == "detail" and ui.sel == 1, "turtle card not open (view %s)", ui.view)
        activate("PAUSE")
        sim.run({ maxTime = 6 })
        H.check(H.appliedCount(tc, "PAUSE") == 1, "turtle applied PAUSE %d times", H.appliedCount(tc, "PAUSE"))
        local r = B.rec(1)
        H.check(r.cmd and r.cmd.name == "PAUSE" and r.cmd.state == "ok", "#12 card: %s %s",
            tostring(r.cmd and r.cmd.name), tostring(r.cmd and r.cmd.state))
        local cmds = H.originals("cmd", tCmd)
        for id, n in pairs(cmds) do H.check(id == 10, "#%d transmitted %d cmd(s): only the leader may", id, n) end
        H.check(cmds[10] == 1, "leader transmitted the cmd %s times", tostring(cmds[10]))
        -- one server as far as turtles can tell: fleets only from the leader, and they reach it
        sim.run({ maxTime = 30 })
        local fleets = H.originals("fleet", 0)
        for id in pairs(fleets) do H.check(id == 10, "#%d sent a fleet (only the leader may)", id) end
        local heard = 0
        for _, e in ipairs(sim.net.log) do
            if e.time > t0 and type(e.msg) == "table" and e.msg.kind == "fleet" and e.from == 11 then heard = heard + 1 end
        end
        H.check(heard > 0, "the gateway never relayed the leader's fleet to the air")
        for _, s in ipairs(all) do
            H.check(#s.c.term._violations == 0, "#%d wrote off screen", s.c.id)
            H.check(s.c.alive, "#%d stopped: %s", s.c.id, tostring(s.c.err))
        end
        return string.format("leader #10 (wired-only), replicas #11 gateway + #12; turtle hop 1; 1 home reply; PAUSE from #12 keyboard applied once (%d cmd tx by leader); %d fleets relayed by the gateway",
            cmds[10], heard)
    end,
}
