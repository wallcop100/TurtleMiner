-- Version: 1.0.0
-- Scenario 16: copper-heavy area fills the inventory with raw_copper (2-5 per block).
-- raw_* is loot (never dropped as trash). Inventory goes "full" mid-vein: the vein
-- backtracks to its start before the turtle heads home (it is on the grid when it
-- reports RETURNING), unloads, and resumes the job at the right step.
return {
    title = "raw ore drops, full mid-vein",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 16, 
            settings = { MAX_CORRIDORS = 1, VEIN_MAX = 64, DROP_TRASH = true } })
        local TY = ctx.worldTargetY
        -- a 3x4x3 copper body right of the main at f=2..4, r=1..4 (branch b=0 at f=4 is inside it)
        local veinCells = 0
        for f = 2, 3 do for r = 1, 3 do for y = TY - 1, TY + 1 do
            H.setGrid(ctx, f, r, y, (y == TY - 1) and "minecraft:deepslate_copper_ore" or "minecraft:copper_ore")
            veinCells = veinCells + 1
        end end end
        local returnPos
        local prev = ctx.srv.onStatus
        ctx.srv.onStatus = function(from, m)
            if prev then prev(from, m) end
            if from == ctx.t.id and m.phase == "RETURNING" and not returnPos
                and tostring(m.reason):lower():find("full") then
                returnPos = { pos = sim.copyPos(ctx.t.pos), reason = m.reason, time = sim.now }
            end
        end
        H.fillWhenAway(ctx, "minecraft:raw_gold", 2, 7)
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "run to DONE through a copper body")
        H.commonChecks(ctx)
        H.check(returnPos, "never went home although the inventory filled (phases %s)", ctx.srv.phaseList(ctx.t.id))
        local f, r = ctx.frame.toGrid(returnPos.pos)
        H.check(H.onGrid(ctx, f, r), "reported RETURNING while still inside the vein at f=%d r=%d (did not backtrack first)", f, r)
        H.check(H.droppedAwayFromHome(ctx, function(n) return n:find("raw_") end) == 0, "raw ore was dropped as trash")
        local cp = ctx.chestPos
        local copper = ctx.w:chestCount(cp.x, cp.y, cp.z, "minecraft:raw_copper")
        H.check(copper >= 2 * veinCells * 0.8, "only %d raw_copper in the chest for a %d-block body", copper, veinCells)
        -- resumed at the right step: the whole main and both branches exist
        local dug = H.dugSet(ctx, TY)
        for fm = 2, ctx.cfg.MAIN_LENGTH do H.check(dug[fm .. ":0"], "main not finished after the unload trip (f=%d)", fm) end
        for rr = 1, ctx.cfg.BRANCH_LENGTH do
            H.check(dug["7:" .. rr] and dug["7:" .. (-rr)], "branch b=1 not mined after resuming (r=%d)", rr)
        end
        return string.format("went home (%s) from the grid, %d raw_copper unloaded", tostring(returnPos.reason), copper)
    end,
}
