-- Version: 1.0.0
-- Scenario 38: SURFACE_IF_LOST (blind turtle, position truly lost after a crash).
--  A: setting on: digs straight up from the tunnel to 8 open cells above ground, then
--     NEEDS_HELP "lost: surfaced here ..."; a second reboot does not climb again
--  B: setting off (default): stays where it is, NEEDS_HELP as before
--  C: low fuel: stops before fuel drops below 50
--  D: a chest above: stops under it, never digs it
-- World: stone up to y=0, air above. Position is lost by crashing with a move in flight and
-- then changing the world's fuel to a value the journal has never seen (19999).
local SURFACED = "lost: surfaced here"

return {
    title = "SURFACE_IF_LOST",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local function gen(_, y) if y > 0 then return "minecraft:air" end return nil end
        local function phaseOf(t)
            local raw = t.fs:read(".tm_state")
            local st = raw and sim.textutils.unserialize(raw)
            return st and st.phase, st and st.reason, st
        end
        -- runs a blind miner into the first branch and loses it there
        local function lose(settings, fuelAfter, worldFn)
            sim.reset()
            local m = H.minerSetup({ id = 38, modem = false, world = { gen = gen }, settings = settings })
            local t = m.t
            local ty = m.worldTargetY
            local crash = H.crashOn(function(e)
                return e.kind == "turtle" and e.op == "forward" and e.when == "before"
                    and e.pos.y == ty and math.abs(e.pos.x) + math.abs(e.pos.z) >= 4
            end)
            m.boot({ crashAt = crash })
            sim.run({ untilFn = function() return not t.computer.alive end, maxTime = 4 * 3600 })
            H.check(crash.fired(), "did not reach the branch to crash there")
            t.fuel = fuelAfter and fuelAfter(t.fuel) or 19999
            if worldFn then worldFn(m.w, t) end
            local at = { x = t.pos.x, y = t.pos.y, z = t.pos.z }
            m.boot()
            H.runUntil(m, function() return phaseOf(t) == "NEEDS_HELP" end, 600, "lost -> NEEDS_HELP")
            sim.run({ maxTime = 60 })
            return m, t, at
        end

        -- A
        local m, t, at = lose({ SURFACE_IF_LOST = true })
        local _, reason = phaseOf(t)
        H.check(tostring(reason):find(SURFACED, 1, true), "A: reason %s", tostring(reason))
        H.check(t.pos.x == at.x and t.pos.z == at.z, "A: moved sideways %s -> %s", H.fmtPos(at), H.fmtPos(t.pos))
        H.check(t.pos.y == 8, "A: expected to stop 8 open cells above ground (y=8), at %s", H.fmtPos(t.pos))
        local climbed = t.pos.y - at.y
        sim.kill(t)
        m.boot()
        sim.run({ maxTime = 120 })
        H.check(t.pos.y == 8, "A: climbed again after a reboot, now at %s", H.fmtPos(t.pos))
        H.check(tostring(select(2, phaseOf(t))):find(SURFACED, 1, true), "A: after reboot reason %s", tostring(select(2, phaseOf(t))))

        -- B
        m, t, at = lose({})
        reason = select(2, phaseOf(t))
        H.check(H.samePos(t.pos, at), "B: moved without SURFACE_IF_LOST: %s -> %s", H.fmtPos(at), H.fmtPos(t.pos))
        H.check(tostring(reason):find("position unknown", 1, true), "B: reason %s", tostring(reason))

        -- C: fuel 56 -> at most 6 moves
        m, t, at = lose({ SURFACE_IF_LOST = true }, function() return 56 end)
        H.check(t.fuel >= 50 and t.pos.y > at.y, "C: fuel %s at %s (from %s)", tostring(t.fuel), H.fmtPos(t.pos), H.fmtPos(at))
        H.check(tostring(select(2, phaseOf(t))):find(SURFACED, 1, true), "C: reason %s", tostring(select(2, phaseOf(t))))

        -- D: a chest 3 above
        local chestAt
        m, t, at = lose({ SURFACE_IF_LOST = true }, nil, function(w, tt)
            chestAt = { x = tt.pos.x, y = tt.pos.y + 3, z = tt.pos.z }
            w:chest(chestAt.x, chestAt.y, chestAt.z, { { name = "minecraft:diamond", count = 1 } })
        end)
        local c = m.w:get(chestAt.x, chestAt.y, chestAt.z)
        H.check(type(c) == "string" and c:find("chest"), "D: the chest above was dug (now %s)", tostring(c))
        H.check(t.pos.y == chestAt.y - 1, "D: expected to stop under the chest, at %s", H.fmtPos(t.pos))
        return string.format("surfaced %d blocks to 8 above ground; off = stays; fuel floor 50; chest above kept", climbed)
    end,
}
