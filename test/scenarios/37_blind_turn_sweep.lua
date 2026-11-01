-- Version: 1.0.0
-- Scenario 37 (review #1 repro): standard run, no GPS. Crash on every turn the miner makes
-- (scan turns, routing turns, home turns), before and after the turn, reboot, and check:
--  * the recovered position/facing is never wrong (every status after the reboot agrees with
--    the world; a wrong facing would show within the first moves)
--  * how many recover on their own vs. stop in NEEDS_HELP (reported; must stay >= the floor)
-- The turtle has a modem only so a fake server can watch what it believes; GPS is off, so
-- recovery is exactly the blind turtle's. SIM_SWEEP_STEP=n tests every n-th turn (default 1).
-- Reference: 14 of 224 recovered before the known-open probe (every stone->stone turn was
-- NEEDS_HELP), 218 of 224 after (the 6 left: turns of the very first home scan).
local FLOOR = 0.95   -- fraction of turn crashes that must recover on their own

-- Runs on the crashed turtle (before the reboot): every cell mine.isKnownOpen claims at the
-- mining level, from the saved job. Each must really be open in the world.
local KO_SRC = [==[
local state, config, mine = require("state"), require("config"), require("mine")
local st = state.load()
local cfg = config.load()
mine.init(st, cfg, {}, {}, {})
if not mine.isKnownOpen then return {} end   -- older mine.lua (before/after comparisons)
local out = {}
for x = -30, 30 do for z = -30, 30 do
    local p = { x = x, y = cfg.TARGET_Y, z = z }
    if mine.isKnownOpen(p) then out[#out + 1] = p end
end end
return out
]==]

return {
    title = "no-GPS turn crash sweep over a standard run",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local function setup()
            sim.reset()
            return H.minerSetup({ id = 37, settings = { MAX_CORRIDORS = tonumber(os.getenv("SIM_SWEEP_CORRIDORS") or "") or 1 } })
        end
        local function isTurn(e)
            return e.kind == "turtle" and (e.op == "turnLeft" or e.op == "turnRight")
        end
        -- count turns in a clean run
        local m = setup()
        local turns = 0
        sim.addHook(m.t, function(e) if isTurn(e) then turns = turns + 1 end end)
        m.boot()
        H.runUntil(m, H.doneAtHome(m), 4 * 3600, "clean run")
        H.check(turns > 20, "only %d turns in a standard run", turns)

        local stepN = tonumber(os.getenv("SIM_SWEEP_STEP") or "") or 1
        local total, ok, helped, home, claimed = 0, 0, 0, 0, 0
        local reasons = {}
        for k = 1, turns, stepN do
            for _, when in ipairs({ "before", "after" }) do
                m = setup()
                local t = m.t
                local crash = H.crashOn(function(e) return isTurn(e) and e.when == when end, k)
                m.boot({ crashAt = crash })
                sim.run({ untilFn = function() return not t.computer.alive end, maxTime = 4 * 3600 })
                if crash.fired() then
                    total = total + 1
                    t.fs:write("kocheck.lua", KO_SRC)
                    local kr = sim.boot(t, { "kocheck" }, { maxTime = 60 })
                    H.check(kr.status == "exit", "kocheck failed: %s %s", tostring(kr.status), tostring(kr.err))
                    for _, p in ipairs(kr.ret[1]) do
                        local nm = tostring(m.w:get(p.x, p.y, p.z))
                        H.check(nm:find("air") or nm:find("water") or nm:find("lava"), "turn %d %s: mine.isKnownOpen claims %s open but it is %s",
                            k, when, H.fmtPos(p), tostring(m.w:get(p.x, p.y, p.z)))
                    end
                    claimed = math.max(claimed, #kr.ret[1])
                    local atHome = H.samePos(t.pos, m.home)
                    m.boot()
                    sim.run({ maxTime = 240, untilFn = function()
                        local p = m.phase()
                        return p == "NEEDS_HELP" or p == "DONE"
                    end })
                    m.watch.assertClean()
                    local p = m.phase()
                    if p == "NEEDS_HELP" then
                        helped = helped + 1
                        if atHome then home = home + 1 end
                        if os.getenv("SIM_SWEEP_DEBUG") then io.stderr:write(string.format("k=%d %s at %s f%d home=%s %s\n", k, when, H.fmtPos(t.pos), t.facing, tostring(atHome), tostring(m.reason()))) end
                        local r = tostring(m.reason())
                        reasons[r] = (reasons[r] or 0) + 1
                    else
                        ok = ok + 1
                    end
                end
            end
        end
        local rs = {}
        for r, n in pairs(reasons) do rs[#rs + 1] = n .. "x " .. r:sub(1, 60) end
        table.sort(rs)
        H.check(ok >= FLOOR * total, "only %d of %d turn crashes recovered (%s)", ok, total, table.concat(rs, "; "))
        return string.format("%d turns; %d of %d turn crashes recovered, %d NEEDS_HELP (%d at home), grid map up to %d cells, all open%s",
            turns, ok, total, helped, home, claimed, #rs > 0 and (": " .. table.concat(rs, "; ")) or "")
    end,
}
