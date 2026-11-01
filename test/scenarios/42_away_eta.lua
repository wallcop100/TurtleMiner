-- Version: 1.0.0
-- Scenario 42 (CM-3): expected absence. A basic-modem turtle under a basic-modem server
-- (real central_monitor) announces `away` with an ETA before every trip.
--  A: normal job with several full trips out of range: never an alert; while silent the card
--     shows AWAY "away, back by ~hh:mm"; later ETAs use the measured trip times.
--  B: the turtle dies silently at depth: no alert until 50% + 2 min past its ETA, then OVERDUE
--     (logged as ALERT).
local HOME = { x = 0, y = 40, z = 0 }

local function setup(sim, H)
    local dummy = H.server({ pos = { x = 100000, y = 0, z = 0 }, modem = "basic", beacon = false })
    local m = H.minerSetup({ id = 1, home = HOME, srv = dummy, chestSize = 200, settings = { TARGET_Y = -30, MAX_CORRIDORS = 4 },
        equip = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" } })
    m.phase = function() return (H.savedPhase(m.t)) end
    local srv = H.monitorComputer({ pos = { x = 0, y = 42, z = 3 }, modemKind = "basic" })
    return m, srv
end

local function simTime(sim, ms) return (ms - sim.BASE_EPOCH) / 1000 end

return {
    title = "away + ETA, overdue-only alerts",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        -- A ------------------------------------------------------------------------
        local m, srv = setup(sim, H)
        local t, M = m.t, srv.M
        -- the first two trips fill the inventory deep in the job (full trips: they predict the next)
        local filled, fills = false, 0
        sim.addHook(t, function()
            if m.atHome() and fills < 2 then filled = false end
            if filled or H.dist(t.pos, HOME) < 95 then return end
            filled = true
            fills = fills + 1
            for s = 1, 16 do t.inv[s] = { name = "minecraft:raw_iron", count = 64 } end
        end)
        local alerts, awaySeen, awayText, trips = {}, 0, nil, {}
        local lastAway
        sim.every(1, function()
            local r = srv.rec(1)
            if not r then return end
            if r.alert then alerts[#alerts + 1] = string.format("t=%.0f %s", sim.now, r.alert) end
            if M.shownPhase(r) == "AWAY" then
                awaySeen = awaySeen + 1
                awayText = M.reasonOf(r)
            end
            if r.away and r.away ~= lastAway then
                lastAway = r.away
                trips[#trips + 1] = { start = sim.now, est = (r.away.eta - r.away.since) / 1000 }
            end
            if lastAway and not r.away and trips[#trips] and not trips[#trips].took then
                trips[#trips].took = sim.now - trips[#trips].start
            end
        end)
        m.boot()
        local okA, errA = pcall(H.runUntil, m, H.doneAtHome(m), 4 * 3600, "A: job done")
        if not okA then H.fail("%s\n%s", tostring(errA.hfail or errA), srv.logText():sub(-1500)) end
        sim.run({ maxTime = 20 })
        H.check(#alerts == 0, "A: alert during a normal job: %s", alerts[1] or "")
        H.check(not srv.logText():find("ALERT", 1, true), "A: ALERT in the log")
        H.check(awaySeen > 30 and awayText and awayText:find("^away, back by ~%d%d:%d%d"),
            "A: card never showed AWAY 'away, back by ~hh:mm' (%d, %s)", awaySeen, tostring(awayText))
        H.check(#trips >= 2, "A: %d away announcements (want >= 2 trips)", #trips)
        local parts = {}
        for i, tr in ipairs(trips) do
            parts[#parts + 1] = string.format("trip%d est %.0fs took %s", i, tr.est, tr.took and string.format("%.0fs", tr.took) or "?")
            if tr.took then
                H.check(tr.took <= tr.est * 1.5 + 120, "A: trip %d took %.0fs, ETA said %.0fs (would alert)", i, tr.took, tr.est)
            end
        end
        local st = sim.textutils.unserialize(t.fs:read(".tm_state"))
        H.check(st.stats.tripSec and st.stats.moveSec, "A: trip times not measured in st.stats")

        -- B ------------------------------------------------------------------------
        sim.reset()
        m, srv = setup(sim, H)
        t, M = m.t, srv.M
        local outAt
        sim.addHook(t, function()
            if H.dist(t.pos, HOME) > 75 then outAt = outAt or sim.now end
        end)
        m.boot()
        H.runUntil(m, function() return outAt and sim.now - outAt > 60 end, 3600, "B: out of range at depth")
        sim.kill(t)
        local r = srv.rec(1)
        H.check(r.away, "B: no away record")
        local due = simTime(sim, r.away.since + math.floor((r.away.eta - r.away.since) * 1.5) + 120000)
        local alertAt
        sim.every(0.5, function()
            if not alertAt and r.alert then alertAt = { sim.now, r.alert } end
        end)
        sim.run({ untilFn = function() return alertAt ~= nil end, maxTime = 4 * 3600 })
        H.check(alertAt, "B: no alert for a turtle dead at depth")
        H.check(alertAt[2] == "OVERDUE", "B: alert %s, want OVERDUE", tostring(alertAt[2]))
        H.check(alertAt[1] >= due and alertAt[1] <= due + 2, "B: alert at t=%.0f, due at t=%.0f", alertAt[1], due)
        H.check(srv.logText():find("ALERT T1 #1: OVERDUE", 1, true), "B: no ALERT line in the log")
        return string.format("A: %s, 0 alerts, %q; B: OVERDUE %.0fs after leaving (ETA %.0fs)", table.concat(parts, ", "),
            tostring(awayText), alertAt[1] - simTime(sim, r.away.since), (r.away.eta - r.away.since) / 1000)
    end,
}
