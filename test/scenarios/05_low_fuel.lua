-- Version: 1.0.0
-- Scenario 5: low fuel -> returns, refuels from coal (fuel chest on top of home),
-- continues; fuel never drops below the distance home while away; coal never
-- dumped into storage; the reserve stays at FUEL_KEEP.
return {
    title = "low fuel",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 5, fuel = 80,
            fuelChest = { { name = "minecraft:coal", count = 64 }, { name = "minecraft:coal", count = 64 } },
            settings = { FUEL_TARGET = 100, FUEL_MARGIN = 20, MAX_CORRIDORS = 3, BRANCH_LENGTH = 6, MAIN_LENGTH = 12 } })
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 8 * 3600, "finish 3 corridors on little fuel")
        H.commonChecks(ctx)
        local firstDig = ctx.w.digLog[1] and ctx.w.digLog[1].time or 0
        local later = {}
        for _, r in ipairs(ctx.t.refuels) do if r.time > firstDig then later[#later + 1] = r end end
        H.check(#later > 0, "no refuel after mining started (%d refuels total) - scenario did not run low", #ctx.t.refuels)
        local fuelTrip = false
        for _, p in ipairs(ctx.srv.phases[ctx.t.id] or {}) do
            if p.phase == "RETURNING" and tostring(p.reason):lower():find("fuel") then fuelTrip = true end
        end
        for _, r in ipairs(later) do if H.samePos(r.pos, ctx.home) then fuelTrip = true end end
        H.check(fuelTrip, "never returned home for fuel (phases %s)", ctx.srv.phaseList(ctx.t.id))
        local after = 0
        for _, d in ipairs(ctx.w.digLog) do if d.time > later[1].time then after = after + 1 end end
        H.check(after > 10, "did not continue mining after refuelling (%d digs after)", after)
        local fp, cp = ctx.fuelChestPos, ctx.chestPos
        H.check(ctx.w:chestCount(fp.x, fp.y, fp.z, "minecraft:coal") < 128, "fuel chest untouched")
        H.check(ctx.w:chestCount(cp.x, cp.y, cp.z, "minecraft:coal") == 0, "coal was dumped into the storage chest")
        local carried = H.invCount(ctx.t, "minecraft:coal")
        H.check(carried <= ctx.cfg.FUEL_KEEP, "turtle hoards %d coal at home (FUEL_KEEP=%d)", carried, ctx.cfg.FUEL_KEEP)
        return string.format("%d refuels after mining started, never stranded", #later)
    end,
}
