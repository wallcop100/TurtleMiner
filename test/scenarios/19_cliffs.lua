-- Version: 1.0.0
-- Scenario 19: tall terrain. Home at Y 150 (mountain), TARGET_Y -58: a 208-block shaft.
-- A dry run with one-way fuel must refuse to leave (NEEDS_HELP "... need N");
-- then it starts with exactly N: it must never run dry away from home and the
-- round trip completes. Variant: no GPS, home at world
-- Y -30 with tminer.HOME_Y = -30 so TARGET_Y -58 means world Y -58.
return {
    title = "cliffs and negative home Y",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local SHAFT = 150 - (-58)
        -- dry run with too little fuel: the miner must refuse to leave and say what it needs
        local ctx = H.minerSetup({ id = 19, gps = true, home = { x = 0, y = 150, z = 0 },
            fuel = SHAFT, settings = { TARGET_Y = -58, MAX_CORRIDORS = 1, FUEL_MARGIN = 20 } })
        ctx.boot()
        H.runUntil(ctx, function() return ctx.phase() == "NEEDS_HELP" end, 3600,
            "with only " .. SHAFT .. " fuel (one way) the miner must refuse to leave")
        H.check(ctx.atHome(), "left home with only one-way fuel")
        local need = tonumber(tostring(ctx.reason()):match("need%D*(%d+)"))
        H.check(need, "NEEDS_HELP reason does not say how much fuel is needed: %s", tostring(ctx.reason()))
        H.check(need >= 2 * SHAFT, "miner says it needs %d fuel to leave, less than the %d-block round trip", need, 2 * SHAFT)

        sim.reset()
        local start = need
        ctx = H.minerSetup({ id = 19, gps = true, home = { x = 0, y = 150, z = 0 },
            fuel = start, settings = { TARGET_Y = -58, MAX_CORRIDORS = 1, FUEL_MARGIN = 20 } })
        ctx.boot()
        H.runUntil(ctx, function()
            local p = ctx.phase()
            return ctx.atHome() and (p == "DONE" or p == "IDLE" or p == "NEEDS_HELP") and #ctx.w.digLog > SHAFT
        end, 6 * 3600, "round trip from Y150 completes")
        ctx.watch.assertClean()
        H.commonChecks(ctx)
        local deep = false
        for _, d in ipairs(ctx.w.digLog) do if d.y == -58 then deep = true end end
        H.check(deep, "never mined at TARGET_Y -58")

        -- no GPS, home at world Y -30, HOME_Y setting
        sim.reset()
        local c2 = H.minerSetup({ id = 20, gps = false, home = { x = 0, y = -30, z = 0 },
            settings = { HOME_Y = -30, TARGET_Y = -58, MAX_CORRIDORS = 1 } })
        c2.boot()
        H.runUntil(c2, function()
            return c2.phase() == "NEEDS_HELP" or H.doneAtHome(c2, 5)()
        end, 4 * 3600, "no-GPS miner with HOME_Y -30 finishes (or asks for help)")
        local lowest = 0
        for _, d in ipairs(c2.w.digLog) do lowest = math.min(lowest, d.y) end
        H.check(lowest == -58, "with HOME_Y=-30 and TARGET_Y=-58 the turtle mined down to world Y %d (expected -58; TARGET_Y treated as relative?)", lowest)
        return string.format("left with exactly the %d fuel it asked for; HOME_Y variant ok", start)
    end,
}
