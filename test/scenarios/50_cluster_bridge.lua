-- Version: 1.0.0
-- Scenario 50 (CG-2 mesh): two wired networks bridged by ONE wireless PC form one cluster.
--   network n1: #20, #21 (wired-only); network n2: #22, #23 (wired-only)
--   #30: wired modem on n1 + basic wireless modem (the only radio), its n2 cable not yet
--   connected. A basic-modem turtle is near #30.
--   A: n2 is cut off: it elects its own leader (#22) and queues a command for a turtle it never
--      heard; n1 + #30 elect #20.
--   B: the n2 cable is plugged into #30 (peripheral event): the two leaders meet, #20 (lower
--      ID, same epoch) stays, #22 hands over its queued command and steps down: one cluster,
--      one leader, every PC follows #20, the merged command is in the queue and the turtle's
--      commands from a PC on n2 work.
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }

return {
    title = "two wired networks + one wireless PC: one cluster, one leader",
    needs = { "net" },
    run = function(sim, H)
        local w = sim.world()
        local n1 = { side = "back", kind = "wired", net = "n1" }
        local n2 = { side = "back", kind = "wired", net = "n2" }
        local pcs = {
            H.serverComputer({ id = 20, modems = { n1 } }),
            H.serverComputer({ id = 21, modems = { n1 } }),
            H.serverComputer({ id = 22, modems = { n2 } }),
            H.serverComputer({ id = 23, modems = { n2 } }),
        }
        local bridge = H.serverComputer({ id = 30, pos = { x = 0, y = 70, z = 0 },
            modems = { n1, { side = "top", kind = "basic" } } })
        pcs[#pcs + 1] = bridge
        local byId = {}
        for _, s in ipairs(pcs) do byId[s.c.id] = s end
        local t = sim.turtle(w, { id = 1, pos = { x = 20, y = 60, z = 0 }, equip = BASIC })
        local tc = H.netTurtle(t)
        sim.run({ maxTime = 20 })
        -- A: two separate clusters
        H.check(byId[20].role() == "leader" and byId[22].role() == "leader", "A: leaders %s/%s",
            byId[20].role(), byId[22].role())
        H.check(byId[23].T.C.leader == 22 and byId[30].T.C.leader == 20, "A: followers wrong")
        H.check(byId[22].rec(1) == nil, "A: the cut-off network heard the turtle")
        local q = byId[22].T.issueCmd(1, "SET", { key = "FOCUS", value = "emerald" })
        H.check(byId[22].T.S.pending[q].queued, "A: command on n2 not queued")
        sim.run({ maxTime = 3 })

        -- B: plug the n2 cable into the bridge
        local tJoin = sim.now
        bridge.c.peripherals.right = sim.modemPeripheral(bridge.c, "right", false, "wired", "n2")
        sim.queue(bridge.c, sim.now, { "peripheral", "right", n = 2 })
        local tOne
        sim.run({ maxTime = 40, untilFn = function()
            local n = 0
            for _, s in ipairs(pcs) do if s.role() == "leader" then n = n + 1 end end
            if n == 1 and byId[22].role() == "replica" then tOne = tOne or sim.now end
            return tOne ~= nil and sim.now - tOne > 8
        end })
        H.check(tOne, "B: still not one cluster 40 s after the bridge was connected")
        for _, s in ipairs(pcs) do
            if s.c.id == 20 then
                H.check(s.role() == "leader", "B: #20 is %s", s.role())
            else
                H.check(s.role() == "replica" and s.T.C.leader == 20, "B: #%d is %s of %s", s.c.id, s.role(),
                    tostring(s.T.C.leader))
            end
        end
        -- the merged command reached the leader's queue and, the turtle being heard, the turtle
        sim.run({ maxTime = 20 })
        H.check(H.appliedCount(tc, "SET", "FOCUS") == 1, "merged command applied %d times", H.appliedCount(tc, "SET", "FOCUS"))
        -- a command from a wired-only PC on n2 now works through the bridge
        local id = byId[23].T.issueCmd(1, "REQUEST_STATUS")
        sim.run({ maxTime = 6 })
        H.check(H.appliedCount(tc, "REQUEST_STATUS") == 1, "command from #23 applied %d times", H.appliedCount(tc, "REQUEST_STATUS"))
        H.check(byId[23].T.S.done[id] and byId[23].T.S.done[id].ok, "#23 does not see its command done")
        local log = byId[23].logText()
        H.check(log:find("merged #22", 1, true), "no merge line in the replicated log:\n%s", log:sub(-800))
        local fleets = H.originals("fleet", tOne)
        for fid in pairs(fleets) do H.check(fid == 20, "#%d sent a fleet after the merge", fid) end
        for _, s in ipairs(pcs) do H.check(s.c.alive, "#%d stopped: %s", s.c.id, tostring(s.c.err)) end
        return string.format("split: leaders #20 + #22; bridge cable in -> one leader (#20) after %.1f s, #22 handed over its queued command (applied once); #23 on n2 commands the turtle",
            tOne - tJoin)
    end,
}
