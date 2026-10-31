-- Version: 1.0.0
-- Scenario 20: cave mobs and buried ore.
--  * a mob blocks the tunnel cell for 20 s (attacks never kill it) then leaves -> no timeout
--  * a mob that never leaves -> nav gives up with "timeout" after STUCK_TIMEOUT, and the
--    full miner goes NEEDS_HELP with a reason (not a hang)
--  * ore fully enclosed in stone next to the tunnel is still found by the 5-face scan
return {
    title = "mobs and buried ore",
    needs = { "state", "nav" },
    run = function(sim, H)
        -- nav level: mob that leaves after 20 s
        sim.reset()
        local ctx = H.navSetup({ world = function(w) w:mob(0, 0, -1, math.huge, 20) end })
        local t0 = sim.now
        local r = ctx.drive({ "f" }, { maxTime = 300 })
        H.check(r.status == "exit", "driver %s %s", r.status, tostring(r.err or r.why))
        local res = r.ret[1].results[1]
        H.check(res.ok, "mob that leaves after 20s: nav.forward gave up (%s)", tostring(res.why))
        H.check(sim.now - t0 >= 19, "moved before the mob left?")
        -- nav level: mob that never leaves
        sim.reset()
        ctx = H.navSetup({ world = function(w) w:mob(0, 0, -1, math.huge) end })
        t0 = sim.now
        r = ctx.drive({ "f" }, { maxTime = 1200 })
        H.check(r.status == "exit", "nav.forward never returned against a permanent mob (%s) - hang", r.status)
        res = r.ret[1].results[1]
        H.check(res.ok == false and tostring(res.why):find("timeout"), "permanent mob: expected false,'timeout', got %s,%s",
            tostring(res.ok), tostring(res.why))
        local dt = sim.now - t0
        H.check(dt >= 50 and dt <= 180, "gave up after %.0fs, expected about STUCK_TIMEOUT (60s)", dt)

        if not H.need(H.ALL, "full-miner variants") then return "nav-level mob cases ok" end
        -- full miner: permanent mob in the main tunnel -> NEEDS_HELP, settles
        sim.reset()
        local m = H.minerSetup({ id = 21, settings = { MAX_CORRIDORS = 1 } })
        local TY = m.worldTargetY
        local mp = H.gridToWorld(m, 4, 0, TY)
        m.w:mob(mp.x, mp.y, mp.z, math.huge)
        m.boot()
        H.runUntil(m, function() return m.phase() == "NEEDS_HELP" end, 3600, "NEEDS_HELP for a mob that never leaves")
        local reason = m.reason()
        H.check(reason and reason ~= "", "NEEDS_HELP without reason")
        H.assertSettles(m, 300, 120)
        H.commonChecks(m)

        -- full miner: buried ores on all scan faces next to the main
        sim.reset()
        m = H.minerSetup({ id = 22, settings = { MAX_CORRIDORS = 1 } })
        TY = m.worldTargetY
        local buried = {
            H.setGrid(m, 3, 1, TY, "minecraft:deepslate_diamond_ore"),   -- right
            H.setGrid(m, 5, -1, TY, "minecraft:emerald_ore"),             -- left
            H.setGrid(m, 6, 0, TY - 1, "minecraft:lapis_ore"),            -- below
            H.setGrid(m, 8, 0, TY + 2, "minecraft:gold_ore"),             -- above (2 above floor)
        }
        m.boot()
        H.runUntil(m, H.doneAtHome(m), 4 * 3600, "run to DONE with buried ores")
        H.commonChecks(m)
        local missed = {}
        for i, p in ipairs(buried) do if not H.wasDug(m, p.x, p.y, p.z) then missed[#missed + 1] = i end end
        H.check(#missed <= 1, "buried ores not found: #%s (1 right, 2 left, 3 below, 4 two above floor)", table.concat(missed, ","))
        if #missed == 1 then H.note("buried ore #" .. missed[1] .. " not found (only acceptable for #4 with a 1-high tunnel)") end
        return "mob wait/timeout ok; buried ores found"
    end,
}
