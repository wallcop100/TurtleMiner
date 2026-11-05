-- Version: 1.0.0
-- Scenario 48 (CG-2): the leader is switched off mid-run.
--   #10 wired-only leader, #11 wired + basic wireless gateway, #12 wired-only.
--   T1 near the gateway (in contact), T2 far away (out of contact: its commands queue).
--   Before: T1's home saved; RETURN_HOME (from #12's UI, forwarded) and SET FOCUS (leader) are
--   queued for T2. The leader is killed; a command typed on #12 during the outage waits.
--   Expected: a replica takes over within ~20 s (#11: same data, lowest live ID); homes and the
--   queued commands survive (same ids); the outage command is delivered once; the old leader
--   reboots and rejoins as a replica; T2 comes into range and applies each queued command
--   exactly once, sent only by the new leader.
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }

return {
    title = "cluster failover: leader off, replica takes over, nothing lost or doubled",
    needs = { "net" },
    run = function(sim, H)
        local w = sim.world()
        local wired = { side = "back", kind = "wired", net = "base" }
        local A = H.serverComputer({ id = 10, modems = { wired } })
        local G = H.serverComputer({ id = 11, pos = { x = 0, y = 70, z = 0 },
            modems = { wired, { side = "top", kind = "basic" } } })
        local B = H.serverComputer({ id = 12, modems = { wired } })
        local t1 = sim.turtle(w, { id = 1, pos = { x = 30, y = 60, z = 0 }, equip = BASIC })
        local t2 = sim.turtle(w, { id = 2, pos = { x = 500, y = 60, z = 0 }, equip = BASIC })
        local c1, c2 = H.netTurtle(t1), H.netTurtle(t2)
        sim.run({ maxTime = 20 })
        H.check(A.role() == "leader" and G.role() == "replica" and B.role() == "replica",
            "start roles %s %s %s", A.role(), G.role(), B.role())
        c1.jobs[#c1.jobs + 1] = function(net)
            net.send("home_save", "server", { home = { x = 30, y = 60, z = 0 }, homeFacing = 1, gps = false })
        end
        sim.run({ maxTime = 2 })
        -- T2 is known (heard once) but now out of contact: commands queue
        A.T.getRec(2, true).lastSeen = sim.BASE_EPOCH + (sim.now - 120) * 1000
        local qRet = B.T.issueCmd(2, "RETURN_HOME")                         -- forwarded from #12
        local qSet = A.T.issueCmd(2, "SET", { key = "FOCUS", value = "gold" }) -- on the leader
        sim.run({ maxTime = 7 })
        for _, s in ipairs({ A, G, B }) do
            for _, id in ipairs({ qRet, qSet }) do
                local p = s.T.S.pending[id]
                H.check(p and p.queued and not p.forwarded, "#%d: command %s not in the replicated queue", s.c.id, id)
            end
            H.check(s.T.S.homes[1], "#%d: no home for T1", s.c.id)
        end

        -- leader off
        local tKill = sim.now
        A.kill()
        sim.run({ maxTime = 1 })
        local qOut = B.T.issueCmd(1, "REQUEST_STATUS")                      -- during the outage
        local tNew
        sim.run({ maxTime = 40, untilFn = function()
            if G.role() == "leader" or B.role() == "leader" then tNew = tNew or sim.now end
            return tNew ~= nil and sim.now - tNew > 3
        end })
        H.check(tNew and tNew - tKill <= 20, "no takeover within 20 s (%s)", tostring(tNew and (tNew - tKill)))
        H.check(G.role() == "leader" and B.role() == "replica" and B.T.C.leader == 11,
            "after failover: #11 %s, #12 %s of %s", G.role(), B.role(), tostring(B.T.C.leader))
        local takeover = tNew - tKill
        for _, id in ipairs({ qRet, qSet }) do
            H.check(G.T.S.pending[id] and G.T.S.pending[id].queued, "new leader lost queued command %s", id)
        end
        H.check(G.T.S.homes[1] and G.T.S.homes[1].homeFacing == 1, "new leader lost T1's home")
        sim.run({ maxTime = 15 })
        H.check(H.appliedCount(c1, "REQUEST_STATUS") == 1, "outage command applied %d times", H.appliedCount(c1, "REQUEST_STATUS"))
        H.check(B.T.S.done[qOut] and B.T.S.done[qOut].ok, "#12 does not see its outage command done")
        -- home_get answered by the new leader only
        local t0 = sim.now
        c1.jobs[#c1.jobs + 1] = function(net) return net.request("home_get", {}, "home", 3) end
        sim.run({ maxTime = 5 })
        local reply = c1.results[#c1.results]
        H.check(type(reply) == "table" and reply.found and reply.homeFacing == 1, "home_get after failover failed")
        local homes, nHome = H.originals("home", t0)
        H.check(nHome == 1 and homes[11] == 1, "%d home replies after failover", nHome)

        -- old leader back: replica
        A.boot()
        sim.run({ maxTime = 15 })
        H.check(A.role() == "replica" and A.T.C.leader == 11 and G.role() == "leader",
            "old leader came back as %s (leader %s), #11 %s", A.role(), tostring(A.T.C.leader), G.role())
        H.check(A.T.S.pending[qRet] and A.T.S.homes[1], "rejoined PC has no copy of the data")

        -- T2 comes into range: each queued command applied exactly once, sent by #11 only
        local tBack = sim.now
        t2.pos = { x = 40, y = 60, z = 0 }
        sim.run({ maxTime = 40 })
        H.check(H.appliedCount(c2, "RETURN_HOME") == 1, "RETURN_HOME applied %d times", H.appliedCount(c2, "RETURN_HOME"))
        H.check(H.appliedCount(c2, "SET", "FOCUS") == 1, "SET FOCUS applied %d times", H.appliedCount(c2, "SET", "FOCUS"))
        local cmds = H.originals("cmd", tBack)
        for id, n in pairs(cmds) do H.check(id == 11, "#%d sent %d cmd(s) after failover", id, n) end
        for _, s in ipairs({ A, G, B }) do
            H.check(s.T.S.pending[qRet] == nil and s.T.S.pending[qSet] == nil, "#%d still shows queued commands", s.c.id)
            H.check(s.c.alive, "#%d stopped: %s", s.c.id, tostring(s.c.err))
        end
        local leaders = 0
        for _, s in ipairs({ A, G, B }) do if s.role() == "leader" then leaders = leaders + 1 end end
        H.check(leaders == 1, "%d leaders at the end", leaders)
        return string.format("takeover by #11 %.1f s after the leader went off; 2 queued + 1 outage command delivered once each; home kept; old leader rejoined as replica",
            takeover)
    end,
}
