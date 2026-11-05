-- Version: 1.0.0
-- Scenario 31 (review #9): GPS turtle with no local state and an old home record on
-- the server.
--  A: far from the record (set up somewhere new): must NOT walk there (a chest sits
--     in between); NEEDS_HELP "state lost"; RESET_HOME makes this spot home.
--  B: carried back to the recorded home while waiting: adopts it on its own.
--  C: in the home shaft below the record: adopts it and climbs home.
return {
    title = "lost state + GPS: adopt server home only when close",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local HOME = { x = 0, y = 64, z = 0 }
        local OLD = { x = 40, y = 64, z = 0 }

        -- A ---------------------------------------------------------------
        local ctx = H.minerSetup({ id = 31, gps = true, fuel = 3000, home = HOME })
        ctx.srv.homes[31] = { home = OLD, homeFacing = 0, gps = true }
        ctx.w:chest(20, 64, 0, { { name = "minecraft:diamond", count = 10 } })
        ctx.boot()
        H.runUntil(ctx, function() return ctx.phase() == "NEEDS_HELP" or ctx.phase() == "UNLOADING" end, 600,
            "A: first decision")
        H.check(ctx.phase() == "NEEDS_HELP", "A: phase %s, expected NEEDS_HELP", tostring(ctx.phase()))
        H.check(tostring(ctx.reason()):find("state lost", 1, true), "A: reason %s", tostring(ctx.reason()))
        H.assertSettles(ctx, 200)
        H.check(H.dist(ctx.t.pos, HOME) <= 1, "A: turtle wandered to %s", H.fmtPos(ctx.t.pos))
        H.check(ctx.w:get(20, 64, 0) ~= "air" and ctx.w:get(20, 64, 0) ~= nil, "A: chest between homes was dug")
        H.check(H.samePos(ctx.srv.homes[31].home, OLD), "A: server record overwritten before RESET_HOME")
        local id = ctx.srv.cmd(31, "RESET_HOME")
        H.runUntil(ctx, function() return ctx.phase() == "IDLE" end, 120, "A: RESET_HOME accepted")
        H.check(ctx.srv.acks[id] and ctx.srv.acks[id][1].ok, "A: RESET_HOME not acked ok")
        H.check(H.samePos(ctx.srv.homes[31].home, HOME), "A: server home is %s after RESET_HOME, expected %s",
            H.fmtPos(ctx.srv.homes[31].home), H.fmtPos(HOME))
        ctx.srv.cmd(31, "RESUME")
        H.runUntil(ctx, H.doneAtHome(ctx), 3600, "A: mines from the new home")
        H.check(ctx.w:get(20, 64, 0) ~= "air", "A: chest between homes was dug")
        H.commonChecks(ctx)

        -- B ---------------------------------------------------------------
        sim.reset()
        ctx = H.minerSetup({ id = 32, gps = true, fuel = 3000, home = HOME })
        ctx.srv.homes[32] = { home = OLD, homeFacing = 0, gps = true }
        ctx.w:chest(OLD.x, OLD.y, OLD.z + 1, {})          -- chest behind the old home
        ctx.w:set(OLD.x, OLD.y, OLD.z, "air")
        ctx.w:set(OLD.x, OLD.y, OLD.z - 1, "air")          -- room for facing calibration
        ctx.boot()
        H.runUntil(ctx, function() return ctx.phase() == "NEEDS_HELP" end, 600, "B: NEEDS_HELP first")
        sim.run({ maxTime = 20 })
        -- carry it to the recorded home by hand
        ctx.w:set(ctx.t.pos.x, ctx.t.pos.y, ctx.t.pos.z, "air")
        ctx.t.pos = { x = OLD.x, y = OLD.y, z = OLD.z }
        ctx.t.prevPos = { x = OLD.x, y = OLD.y, z = OLD.z }
        H.runUntil(ctx, function()
            local s = ctx.srv.status[32]
            return s and s.phase == "UNLOADING" and H.samePos(s.home, OLD)
        end, 300, "B: adopts the record once carried home")

        -- C ---------------------------------------------------------------
        sim.reset()
        ctx = H.minerSetup({ id = 33, gps = true, fuel = 3000, home = HOME })
        ctx.srv.homes[33] = { home = HOME, homeFacing = 0, gps = true }
        -- turtle sits 4 blocks down its own shaft, room in front for calibration
        local start = { x = 0, y = 60, z = 0 }
        for y = 60, 63 do ctx.w:set(0, y, 0, "air") end
        ctx.w:set(0, 60, -1, "air")
        ctx.t.pos = { x = start.x, y = start.y, z = start.z }
        ctx.t.prevPos = { x = start.x, y = start.y, z = start.z }
        ctx.boot()
        H.runUntil(ctx, function() return ctx.srv.phaseSeen(33, "UNLOADING") ~= nil or ctx.phase() == "NEEDS_HELP" end,
            600, "C: home from the shaft")
        H.notNeedsHelp(ctx)
        H.check(H.samePos(ctx.srv.status[33].home, HOME), "C: home %s", H.fmtPos(ctx.srv.status[33].home))
        H.commonChecks(ctx)
        return "far: NEEDS_HELP + RESET_HOME; carried home: adopted; in shaft: adopted"
    end,
}
