-- Version: 1.0.0
-- Scenario 43 (CM-4): catch-up log. A basic-modem turtle mines three small iron veins out of
-- range of a basic-modem server (real central_monitor). Nothing is sent while out of contact;
-- the events are buffered (coalesced: "vein iron x2" three times = one entry x3) and arrive in
-- one `catchup` message when contact returns. The monitor merges them into
-- miner_events.log with their original timestamps (sorted into the log, not at arrival time).
return {
    title = "catch-up event log with original timestamps",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local HOME = { x = 0, y = 40, z = 0 }
        local dummy = H.server({ pos = { x = 100000, y = 0, z = 0 }, modem = "basic", beacon = false })
        local m = H.minerSetup({ id = 1, home = HOME, srv = dummy, settings = { TARGET_Y = -30, MAX_CORRIDORS = 1 },
            equip = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" } })
        local t = m.t
        m.phase = function() return (H.savedPhase(t)) end
        local TY = -30
        local ores = {}
        for _, v in ipairs({ { 2, 1 }, { 2, 2 }, { 6, -1 }, { 6, -2 }, { 8, 2 }, { 8, 3 } }) do
            ores[#ores + 1] = H.setGrid(m, v[1], v[2], TY, "minecraft:iron_ore")
        end
        local firstVein
        sim.addHook(t, function(e)
            if firstVein or e.when ~= "after" or not e.ok then return end
            for _, p in ipairs(ores) do if H.samePos(p, t.pos) then firstVein = sim.now end end
        end)
        local srv = H.monitorComputer({ pos = { x = 0, y = 42, z = 3 }, modemKind = "basic" })
        local catchupAt, catchupMsg, events = nil, nil, 0
        sim.net.tap(function(from, to, msg)
            if from ~= 1 or type(msg) ~= "table" then return end
            if msg.kind == "catchup" and not catchupAt then catchupAt, catchupMsg = sim.now, msg end
            if msg.kind == "event" and firstVein and not catchupAt then events = events + 1 end
        end)
        m.boot()
        H.runUntil(m, H.doneAtHome(m), 4 * 3600, "job done")
        sim.run({ maxTime = 10 })
        H.check(firstVein, "turtle never mined the veins")
        H.check(catchupAt, "no catchup message")
        H.check(events == 0, "%d event messages sent while out of contact", events)
        local veinEntry
        for _, e in ipairs(catchupMsg.events) do
            if e.text:find("^vein iron") then veinEntry = e end
        end
        H.check(veinEntry and veinEntry.n == 3, "veins not coalesced into one entry x3 (%s)",
            veinEntry and tostring(veinEntry.n) or "none")
        -- the log line carries the original time, not the arrival time
        local line
        for _, l in ipairs(srv.M.S.log) do
            if l:find("vein iron", 1, true) and l:find("catch-up", 1, true) then line = l end
        end
        H.check(line, "catch-up vein line missing from the log:\n%s", srv.logText():sub(-1200))
        H.check(line:find("(x3)", 1, true), "coalesced count not shown: %s", line)
        local function stampAt(simT) return os.date("!%m-%d %H:%M:%S", math.floor(sim.BASE_EPOCH / 1000 + simT)) end
        local st = line:sub(1, 14)
        H.check(st >= stampAt(firstVein - 1) and st <= stampAt(firstVein + 30),
            "log line stamped %s; vein mined at %s, catch-up arrived %s", st, stampAt(firstVein), stampAt(catchupAt))
        H.check(catchupAt - firstVein > 30, "catch-up came only %.0fs after the vein (was it out of range?)", catchupAt - firstVein)
        local prev = ""
        for _, l in ipairs(srv.M.S.log) do
            H.check(l:sub(1, 14) >= prev, "log not in time order at: %s", l)
            prev = l:sub(1, 14)
        end
        local f = srv.c.fs:read("miner_events.log") or ""
        H.check(f:find(line, 1, true), "catch-up line not written to miner_events.log")
        return string.format("vein at %s, catch-up arrived %s (%.0fs later, %d entries): %s", stampAt(firstVein),
            stampAt(catchupAt), catchupAt - firstVein, #catchupMsg.events, line)
    end,
}
