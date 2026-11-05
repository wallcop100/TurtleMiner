-- Version: 1.0.0
-- Scenario 30 (review #7): a DONE turtle continues after SET MAX_CORRIDORS + RESUME,
-- also after a REBOOT; without a raise RESUME keeps it DONE; RESET_JOB + RESUME
-- restarts the grid at corridor 0.
return {
    title = "DONE: raise MAX_CORRIDORS / RESET_JOB, then RESUME",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 30, settings = { MAX_CORRIDORS = 1 } })
        local srv = ctx.srv
        local function corridor()
            local s = srv.status[30]
            return s and type(s.job) == "table" and s.job.corridor
        end
        local function doneAtHome() return ctx.phase() == "DONE" and ctx.atHome() end
        ctx.boot()
        H.runUntil(ctx, doneAtHome, 4 * 3600, "first DONE (1 corridor)")
        H.check(corridor() == 1, "DONE with job corridor %s, expected 1", tostring(corridor()))

        -- Raise the limit, RESUME: mines corridor 1 and is DONE again at 2.
        local idSet = srv.cmd(30, "SET", { key = "MAX_CORRIDORS", value = 2 })
        sim.run({ maxTime = 5 })
        H.check(srv.acks[idSet] and srv.acks[idSet][1].ok, "SET MAX_CORRIDORS not acked ok")
        local dug0 = #H.dugGrid(ctx)
        srv.cmd(30, "RESUME")
        H.runUntil(ctx, function() return ctx.phase() ~= "DONE" end, 120, "RESUME leaves DONE after raising MAX_CORRIDORS")
        H.runUntil(ctx, function() return doneAtHome() and corridor() == 2 end, 4 * 3600, "second DONE at corridor 2")
        H.check(#H.dugGrid(ctx) > dug0 + 10, "RESUME after the raise dug only %d blocks", #H.dugGrid(ctx) - dug0)

        -- REBOOT while DONE (as the monitor button does), raise again, RESUME.
        local bootN, hellos = ctx.t.computer.bootN, #srv.hellos
        srv.cmd(30, "REBOOT")
        H.runUntil(ctx, function() return ctx.t.computer.bootN > bootN and #srv.hellos > hellos end, 300, "REBOOT restarts the miner")
        sim.run({ maxTime = 10 })
        H.check(doneAtHome(), "not DONE at home after REBOOT: %s", tostring(ctx.phase()))
        local idS3 = srv.cmd(30, "SET", { key = "MAX_CORRIDORS", value = 3 })
        sim.run({ maxTime = 5 })
        H.check(srv.acks[idS3] and srv.acks[idS3][1].ok, "SET after reboot not acked ok")
        local idRes = srv.cmd(30, "RESUME")
        sim.run({ maxTime = 5 })
        H.check(srv.acks[idRes] and srv.acks[idRes][1].ok, "RESUME after reboot not acked ok")
        H.runUntil(ctx, function() return doneAtHome() and corridor() == 3 end, 4 * 3600, "third DONE after reboot + raise")

        -- No raise: RESUME keeps it DONE.
        srv.cmd(30, "RESUME")
        sim.run({ maxTime = 90 })
        H.check(ctx.phase() == "DONE", "RESUME without a raise left DONE: %s", tostring(ctx.phase()))

        -- RESET_JOB + RESUME: back to corridor 0.
        local idR = srv.cmd(30, "RESET_JOB")
        sim.run({ maxTime = 5 })
        H.check(srv.acks[idR] and srv.acks[idR][1].ok, "RESET_JOB not acked ok")
        srv.cmd(30, "RESUME")
        H.runUntil(ctx, function()
            local p = ctx.phase()
            return (p == "MINING" or p == "TO_WORK") and corridor() == 0
        end, 600, "RESET_JOB + RESUME restarts at corridor 0")
        H.commonChecks(ctx)
        return "DONE -> raise -> DONE(2) -> reboot -> raise -> DONE(3) -> RESET_JOB -> corridor 0"
    end,
}
