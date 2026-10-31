-- Version: 1.0.0
-- Scenario 2: crash after each kind of op (forward, back, up, down, turn, mid-save,
-- mid-journal-write) -> reboot -> nav.recover gives the right position + facing,
-- with and without GPS. Never a silent wrong answer; without GPS a turn crash may
-- legitimately end in NEEDS_HELP ("facing unknown"). Full-miner variant if present.
local OPS = { "f", "f", "u", "r", "f", "s", "d", "l", "f", "b", "f", "r", "f" }
local NAME = { f = "forward", b = "back", u = "up", d = "down", l = "turnLeft", r = "turnRight" }

return {
    title = "crash recovery",
    needs = { "state", "nav" },
    run = function(sim, H)
        local cases = {}
        for _, op in ipairs({ "f", "b", "u", "d", "l", "r" }) do
            local n = (op == "f") and 2 or 1
            local turn = (op == "l" or op == "r")
            cases[#cases + 1] = { name = NAME[op] .. " before move (after intent)", turn = turn,
                crash = function() return H.crashOn(H.isTurtleOp(NAME[op], "before"), n) end }
            cases[#cases + 1] = { name = NAME[op] .. " after move (before done)", turn = turn,
                crash = function() return H.crashOn(H.isTurtleOp(NAME[op], "after"), n) end }
            cases[#cases + 1] = { name = NAME[op] .. " mid intent write", turn = turn,
                crash = function() return H.crashOn(H.isJournalWrite("I", op), n) end }
            cases[#cases + 1] = { name = NAME[op] .. " mid done write", turn = turn,
                crash = function() return H.crashOnWriteAfterOp(NAME[op], n, H.isJournalWrite("D")) end }
        end
        cases[#cases + 1] = { name = "mid-save (truncated .tm_state.tmp)",
            crash = function() return H.crashOn(H.isClose("tm_state%.tmp$"), 2) end }
        cases[#cases + 1] = { name = "mid-save (old deleted, tmp not yet moved)",
            crash = function() return H.crashOn(H.isMove("tm_state$"), 2) end }

        local results, helped = 0, 0
        for _, gps in ipairs({ false, true }) do
            for _, case in ipairs(cases) do
                sim.reset()
                -- GPS runs happen in an open cave so facing calibration always has room;
                -- no-GPS runs dig through solid stone.
                local ctx = H.navSetup({ gps = gps, world = gps and function(w)
                    w:fill(94, 8, -56, 106, 14, -44, "air")
                end or nil })
                local label = (gps and "GPS " or "no-GPS ") .. case.name
                local r = ctx.drive(OPS, { crashAt = case.crash() })
                H.check(r.status == "crashed", "%s: driver should have crashed, got %s %s", label, r.status,
                    tostring(r.err or ""):sub(1, 300))
                local p = ctx.probe()
                H.check(not p.noState, "%s: state.load() returned nil after the crash (state lost)", label)
                if p.ok then
                    local okm, wp, wf = ctx.matches(p)
                    H.check(okm, "%s: recovered to %s facing %s but turtle is at %s facing %d", label,
                        H.fmtPos(wp), tostring(wf), H.fmtPos(ctx.t.pos), ctx.t.facing)
                else
                    -- GPS facing calibration needs a free cell (forward, back, or up); if the turtle
                    -- is boxed in, reporting NEEDS_HELP is the contract, not a failure.
                    local t = ctx.t
                    local function solid(dx, dy, dz) return not ctx.w:passable(t.pos.x + dx, t.pos.y + dy, t.pos.z + dz) end
                    local F = H.DIRS[t.facing]
                    -- contract probe order: forward, else back, else up+forward
                    local boxed = solid(F.x, 0, F.z) and solid(-F.x, 0, -F.z) and (solid(0, 1, 0) or solid(F.x, 1, F.z))
                    H.check(case.turn and (not gps or boxed), "%s: nav.recover failed (%s) where it must succeed%s", label,
                        tostring(p.reason), gps and case.turn and " (a free cell was available for GPS calibration)" or "")
                    H.check(p.reason and p.reason ~= "", "%s: recover failed without a reason", label)
                    helped = helped + 1
                end
                results = results + 1
            end
        end

        if H.need(H.ALL, "full-miner variant") then
            for _, gps in ipairs({ false, true }) do
                for _, which in ipairs({ "move", "save" }) do
                    sim.reset()
                    local ctx = H.minerSetup({ id = 2, gps = gps, home = gps and { x = 40, y = 20, z = 40 } or nil })
                    local crash = which == "move" and H.crashOn(H.isTurtleOp("forward", "after"), 30)
                        or H.crashOn(H.isClose("tm_state%.tmp$"), 3)
                    ctx.boot({ crashAt = crash })
                    sim.run({ untilFn = function() return not ctx.t.computer.alive end, maxTime = 3600 })
                    H.check(ctx.t.computer.status == "crashed", "full miner (%s, gps=%s) did not crash as planned: %s %s",
                        which, tostring(gps), ctx.t.computer.status, tostring(ctx.t.computer.err))
                    ctx.boot()
                    H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600,
                        "after crash (" .. which .. ", gps=" .. tostring(gps) .. ") miner should finish at home")
                    H.commonChecks(ctx)
                end
            end
        end
        return string.format("%d crash cases ok (%d no-GPS turn cases reported NEEDS_HELP instead of guessing)", results, helped)
    end,
}
