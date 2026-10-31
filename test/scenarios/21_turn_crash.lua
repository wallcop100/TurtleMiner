-- Version: 1.0.0
-- Scenario 21 (review #1): crash during a turn.
--  GPS: calibrateFacing works inside a 1x1 tunnel (turns to find the open side), and when fully
--       boxed in away from home it digs one block to probe, never a protected block.
--  no GPS: the block name stored in the turn intent settles the turn when the block in front
--       changed; an unchanged front stays NEEDS_HELP (never a guess).
return {
    title = "turn crash recovery",
    needs = { "state", "nav" },
    run = function(sim, H)
        local notes = {}
        local function crashRun(label, setup, ops, crashOp, when, n, after)
            sim.reset()
            local ctx = H.navSetup(setup)
            local r = ctx.drive(ops, { crashAt = H.crashOn(H.isTurtleOp(crashOp, when), n or 1) })
            H.check(r.status == "crashed", "%s: driver should have crashed, got %s %s", label, r.status,
                tostring(r.err or ""):sub(1, 300))
            if after then after(ctx) end
            local dug0 = #ctx.w.digLog
            local p = ctx.probe()
            return ctx, p, #ctx.w.digLog - dug0
        end
        local function mustMatch(label, ctx, p)
            H.check(p.ok, "%s: recover failed: %s", label, tostring(p.reason))
            local okm, wp, wf = ctx.matches(p)
            H.check(okm, "%s: recovered to %s facing %s but turtle is at %s facing %d", label,
                H.fmtPos(wp), tostring(wf), H.fmtPos(ctx.t.pos), ctx.t.facing)
        end

        -- GPS, 1x1 tunnel, crash after the turn: front/back/up are stone, only the side the
        -- turtle came from is open. Must recover without digging.
        local ctx, p, dug = crashRun("GPS 1x1 after turn", { gps = true }, { "f", "f", "f", "l" },
            "turnLeft", "after")
        mustMatch("GPS 1x1 after turn", ctx, p)
        H.check(dug == 0, "GPS 1x1 after turn: calibration dug %d blocks, the tunnel was open", dug)
        H.check(H.samePos(ctx.t.pos, { x = 103, y = 10, z = -50 }), "GPS 1x1: turtle not back in place: %s",
            H.fmtPos(ctx.t.pos))

        -- GPS, 1x1 tunnel, crash before the turn
        ctx, p, dug = crashRun("GPS 1x1 before turn", { gps = true }, { "f", "f", "f", "l" }, "turnLeft", "before")
        mustMatch("GPS 1x1 before turn", ctx, p)
        H.check(dug == 0, "GPS 1x1 before turn: calibration dug %d blocks", dug)

        -- GPS, boxed in away from home: the cell it came from is now a chest. Calibration must
        -- skip the chest and dig a plain block instead.
        ctx, p, dug = crashRun("GPS boxed", { gps = true }, { "f", "l" }, "turnLeft", "after", 1, function(c)
            c.w:chest(100, 10, -50, { { name = "minecraft:diamond", count = 3 } })
        end)
        mustMatch("GPS boxed", ctx, p)
        H.check(dug == 1, "GPS boxed: expected exactly one probe dig, got %d", dug)
        local chest = ctx.w:get(100, 10, -50)
        H.check(type(chest) == "string" and chest:find("chest"), "GPS boxed: chest was dug (cell now %s)", tostring(chest))

        -- no GPS: facing along the open tunnel, turn right -> front changes air -> stone
        ctx, p = crashRun("no-GPS turnRight after", {}, { "f", "f", "b", "r" }, "turnRight", "after")
        mustMatch("no-GPS turnRight after", ctx, p)
        -- facing the stone wall, turn left -> front changes stone -> air
        ctx, p = crashRun("no-GPS turnLeft after", {}, { "f", "f", "b", "r", "l" }, "turnLeft", "after")
        mustMatch("no-GPS turnLeft after", ctx, p)
        -- turn did not happen: front unchanged (stone -> stone) -> may not guess
        ctx, p = crashRun("no-GPS turnLeft before", {}, { "f", "f", "b", "r", "l" }, "turnLeft", "before")
        if p.ok then
            mustMatch("no-GPS turnLeft before", ctx, p)
        else
            H.check(tostring(p.reason):find("facing"), "no-GPS turnLeft before: unexpected reason %s", tostring(p.reason))
            notes[#notes + 1] = "unchanged front -> NEEDS_HELP"
        end
        -- turn into a side identical to the old front (stone wall -> stone wall): must not guess
        ctx, p = crashRun("no-GPS stone->stone", {}, { "f", "l" }, "turnLeft", "after")
        if p.ok then
            mustMatch("no-GPS stone->stone", ctx, p)
        else
            H.check(tostring(p.reason):find("facing"), "no-GPS stone->stone: unexpected reason %s", tostring(p.reason))
        end
        return "GPS 1x1/boxed + no-GPS changed-front turn crashes recovered; " .. table.concat(notes, ", ")
    end,
}
