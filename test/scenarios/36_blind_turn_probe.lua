-- Version: 1.0.0
-- Scenario 36 (review #1/#5, blind turtle): no GPS, crash during a turn whose front block did
-- not change (stone wall -> stone wall in a 1x1 tunnel). nav.recover probes the 4 neighbours
-- and matches them against the known-open map (journal cells), so the facing is settled
-- without a guess:
--  A: tunnel end and tunnel middle, turnLeft/turnRight, crash before and after the turn
--  B: crash during the probe itself (each probe turn, before and after) -> next boot probes
--     again and still gets it right
--  C: open cave all around: every facing fits -> NEEDS_HELP "facing unknown" (never a guess)
--  D: unlimited fuel, move in flight into fresh rock: settled by the known-open map when the
--     two candidates differ; never wrong
local NAME = { l = "turnLeft", r = "turnRight" }

return {
    title = "blind turn crash: probe + known-open map",
    needs = { "state", "nav" },
    run = function(sim, H)
        local function crashDrive(setup, ops, pred, n)
            sim.reset()
            local ctx = H.navSetup(setup)
            local r = ctx.drive(ops, { crashAt = H.crashOn(pred, n or 1) })
            H.check(r.status == "crashed", "driver should have crashed, got %s %s", r.status,
                tostring(r.err or ""):sub(1, 300))
            return ctx
        end
        local function mustMatch(label, ctx, p)
            H.check(p.ok, "%s: recover failed: %s", label, tostring(p.reason))
            local okm, wp, wf = ctx.matches(p)
            H.check(okm, "%s: recovered to %s facing %s but turtle is at %s facing %d", label,
                H.fmtPos(wp), tostring(wf), H.fmtPos(ctx.t.pos), ctx.t.facing)
        end

        -- A
        local A = 0
        local shapes = {
            { "end", { "f", "f", "f" } },
            { "middle", { "f", "f", "f", "f", "b", "b" } },
        }
        for _, sh in ipairs(shapes) do
            for _, op in ipairs({ "l", "r" }) do
                for _, when in ipairs({ "before", "after" }) do
                    local ops = {}
                    for i, o in ipairs(sh[2]) do ops[i] = o end
                    ops[#ops + 1] = op
                    local label = "A " .. sh[1] .. " " .. NAME[op] .. " " .. when
                    local ctx = crashDrive({}, ops, H.isTurtleOp(NAME[op], when))
                    local dug0 = #ctx.w.digLog
                    mustMatch(label, ctx, ctx.probe())
                    H.check(#ctx.w.digLog == dug0, "%s: the probe dug", label)
                    A = A + 1
                end
            end
        end

        -- B: crash during the probe (probe turns are turnRight; the crashed op was a turnLeft)
        local B = 0
        for n = 1, 3 do
            for _, when in ipairs({ "before", "after" }) do
                local label = "B probe turn " .. n .. " " .. when
                local ctx = crashDrive({}, { "f", "f", "f", "l" }, H.isTurtleOp("turnLeft", "after"))
                local r = sim.boot(ctx.t, { "probe" }, { maxTime = 300,
                    crashAt = H.crashOn(H.isTurtleOp("turnRight", when), n) })
                H.check(r.status == "crashed", "%s: probe should have crashed, got %s", label, r.status)
                mustMatch(label, ctx, ctx.probe())
                B = B + 1
            end
        end
        -- and two crashes in a row inside probes
        do
            local ctx = crashDrive({}, { "f", "f", "f", "r" }, H.isTurtleOp("turnRight", "before"))
            sim.boot(ctx.t, { "probe" }, { maxTime = 300, crashAt = H.crashOn(H.isTurtleOp("turnRight", "after"), 2) })
            sim.boot(ctx.t, { "probe" }, { maxTime = 300, crashAt = H.crashOn(H.isTurtleOp("turnRight", "before"), 1) })
            mustMatch("B double probe crash", ctx, ctx.probe())
            B = B + 1
        end

        -- C: open cave around the turtle: cannot be told apart -> NEEDS_HELP, never a guess
        local ctx = crashDrive({ world = function(w) w:fill(-3, 0, -6, 3, 0, -4, "air") end },
            { "f", "f", "f", "f", "f", "l" }, H.isTurtleOp("turnLeft", "after"))
        local p = ctx.probe()
        if p.ok then
            mustMatch("C cave", ctx, p)
            H.fail("C cave: expected NEEDS_HELP in a symmetric cave, got a (correct) answer")
        end
        H.check(tostring(p.reason):find("facing unknown"), "C cave: unexpected reason %s", tostring(p.reason))

        -- D: unlimited fuel, crash on a forward into a freshly dug cell
        local D, Dhelp = 0, 0
        for _, when in ipairs({ "before", "after" }) do
            for _, n in ipairs({ 3, 4 }) do
                local label = "D unlimited forward #" .. n .. " " .. when
                local c2 = crashDrive({ fuel = "unlimited" }, { "f", "f", "f", "f", "f" },
                    H.isTurtleOp("forward", when), n)
                local q = c2.probe()
                if q.ok then mustMatch(label, c2, q); D = D + 1
                else
                    H.check(tostring(q.reason):find("position unknown"), "%s: unexpected reason %s", label, tostring(q.reason))
                    Dhelp = Dhelp + 1
                end
            end
        end
        H.check(D >= 2, "D: expected the 'moved into fresh rock' cases to be settled, settled %d", D)

        return string.format("A %d turn crashes settled by probing, B %d mid-probe crashes, C cave -> NEEDS_HELP, D unlimited moves %d settled / %d NEEDS_HELP",
            A, B, D, Dhelp)
    end,
}
