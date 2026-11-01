-- Version: 1.0.0
-- Scenario 41 (CM-2): a basic-modem turtle under a basic-modem server (real central_monitor,
-- 64-block range) loses contact about 60 blocks down the shaft. While it is out of range:
--  - it sends nothing (status sends skipped, no wasted work)
--  - RETURN_HOME issued on the monitor is queued (card "queued"), not transmitted
-- When the turtle comes back into range the command is delivered (first `cmd` only after the
-- turtle was heard again), acked, applied once, and the turtle ends IDLE at home.
return {
    title = "store-and-forward commands out of range",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local HOME = { x = 0, y = 40, z = 0 }
        local dummy = H.server({ pos = { x = 100000, y = 0, z = 0 }, modem = "basic", beacon = false })
        local m = H.minerSetup({ id = 1, home = HOME, srv = dummy, settings = { TARGET_Y = -30, MAX_CORRIDORS = 4 },
            equip = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" } })
        local t = m.t
        m.phase = function() return (H.savedPhase(t)) end
        -- inventory fills deep in the job: it comes back "inventory full" and would go out again
        local filled = false
        sim.addHook(t, function()
            if filled or H.dist(t.pos, HOME) < 95 then return end
            filled = true
            for s = 1, 16 do t.inv[s] = { name = "minecraft:raw_iron", count = 64 } end
        end)
        local srv = H.monitorComputer({ pos = { x = 0, y = 42, z = 3 }, modemKind = "basic" })
        local M = srv.M
        local function dist() local p, q = t.pos, srv.c.pos
            return math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2) end
        local outAt
        sim.addHook(t, function()
            if dist() > 64 then outAt = outAt or sim.now else outAt = nil end
        end)
        m.boot()
        H.runUntil(m, function() return M.S.turtles[1] ~= nil end, 120, "monitor hears the turtle at home")
        H.runUntil(m, function() return outAt and sim.now - outAt > 40 and t.pos.y == -30 end, 3600,
            "turtle out of range at depth")
        local r = srv.rec(1)
        H.check(sim.BASE_EPOCH + sim.now * 1000 - r.lastSeen > 30000, "monitor still hears the turtle at depth")
        local tOut = outAt
        local quiet = H.sentBy(1, outAt + 31, sim.now)
        H.check(quiet == 0, "turtle sent %d messages while out of contact (status should be skipped)", quiet)
        -- RETURN_HOME while out of range: queued
        local tCmd = sim.now
        local id = M.issueCmd(1, "RETURN_HOME")
        local p = M.S.pending[id]
        H.check(p and p.queued, "RETURN_HOME not queued for a turtle out of range")
        H.check(r.cmd and r.cmd.state == "queued", "card shows %s, not queued", tostring(r.cmd and r.cmd.state))
        -- a newer command of the same kind replaces a queued one; the pocket path queues the same way
        local set1 = M.issueCmd(1, "SET", { key = "FOCUS", value = "iron" })
        local pocket = H.server({ id = 50, pos = { x = 3, y = 42, z = 3 }, modem = "basic", beacon = false })
        pocket.send(100, "cmd_relay", { target = 1, cmd = "SET", params = { key = "FOCUS", value = "diamond" }, id = "pk-1" }, false)
        sim.run({ maxTime = 1 })
        H.check(M.S.pending[set1] == nil and M.S.done[set1] and M.S.done[set1].err == "replaced",
            "older SET FOCUS not replaced by the pocket's newer one")
        local function pocketAck(pred)
            for _, e in ipairs(pocket.msgs) do
                if e.msg.kind == "ack" and e.msg.id == "pk-1" and pred(e.msg) then return e end
            end
        end
        H.check(pocketAck(function(a) return a.queued end), "pocket got no 'queued' ack for its command")
        H.check(M.S.pending["pk-1"] and M.S.pending["pk-1"].queued, "pocket command not queued on the server")
        -- expiry: a command for a turtle never heard again is dropped after 24 h
        local lost = M.issueCmd(77, "PAUSE")
        M.S.pending[lost].created = M.S.pending[lost].created - 24 * 3600 * 1000 - 1
        sim.run({ maxTime = 1 })
        H.check(M.S.pending[lost] == nil and srv.rec(77).cmd.err == "expired", "queued command did not expire after 24 h")
        -- comes back (job done / full), is heard, gets the command
        local heardAgain
        sim.net.tap(function(from, to, msg)
            if from == 1 and not heardAgain and sim.now > tCmd and dist() <= 64 then heardAgain = sim.now end
        end)
        H.runUntil(m, function() return M.S.pending[id] == nil end, 4 * 3600, "queued RETURN_HOME delivered and acked")
        H.check(r.cmd.state == "ok", "RETURN_HOME ended %s %s", tostring(r.cmd.state), tostring(r.cmd.err))
        local firstCmd
        for _, e in ipairs(sim.net.log) do
            if e.from == 100 and e.time >= tCmd and type(e.msg) == "table" and e.msg.kind == "cmd" and e.msg.id == id then
                firstCmd = firstCmd or e.time
            end
        end
        H.check(heardAgain and firstCmd and firstCmd >= heardAgain,
            "cmd transmitted at %s before the turtle was heard again (%s)", tostring(firstCmd), tostring(heardAgain))
        H.runUntil(m, function() return m.phase() == "IDLE" and m.atHome() end, 1800, "turtle IDLE at home after RETURN_HOME")
        local _, why = H.savedPhase(t)
        sim.run({ maxTime = 15, untilFn = function() return M.S.pending["pk-1"] == nil end })
        sim.run({ maxTime = 15 })
        H.check(srv.rec(1).st.phase == "IDLE", "monitor shows %s", tostring(srv.rec(1).st.phase))
        H.check(pocketAck(function(a) return a.ok == true end), "pocket never got the final ok for its queued command")
        local settings = sim.textutils.unserialize(t.fs:read(".settings") or "{}") or {}
        H.check(settings["tminer.FOCUS"] == "diamond", "turtle FOCUS is %s, want diamond (pocket's command)",
            tostring(settings["tminer.FOCUS"]))
        local applied = 0
        for _, e in ipairs(sim.net.log) do
            if e.from == 1 and type(e.msg) == "table" and e.msg.kind == "event" and tostring(e.msg.text):find("set FOCUS", 1, true) then
                applied = applied + 1
            end
        end
        H.check(applied == 1, "SET FOCUS applied %d times", applied)
        return string.format("out of range %.0fs (0 msgs sent); queued %.0fs, delivered %.1fs after the turtle was heard; IDLE (%s); pocket cmd queued + replaced older, applied once; 24 h expiry",
            tCmd - tOut, heardAgain - tCmd, firstCmd - heardAgain, tostring(why))
    end,
}
