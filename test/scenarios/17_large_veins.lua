-- Version: 1.0.0
-- Scenario 17: 1.18 large ore veins: iron_ore + raw_iron_block in tuff/granite filler.
-- raw_*_block should be detected as ore (reported if not), VEIN_MAX caps each vein
-- cleanly (the turtle comes back onto the grid), filler is trash and not vein-mined.
return {
    title = "large ore veins",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local defaults = H.configDefaults()
        H.check(H.inList(defaults.TRASH, "minecraft:tuff") and H.inList(defaults.TRASH, "minecraft:granite"),
            "tuff/granite filler is not in cfg.TRASH")
        local VMAX = 8
        local ctx = H.minerSetup({ id = 17, settings = { MAX_CORRIDORS = 1, VEIN_MAX = VMAX, BRANCH_LENGTH = 6 } })
        local TY = ctx.worldTargetY
        local blocks, filler = {}, {}
        -- body left of the main at f=2..3, r=-6..-1, y TY-1..TY+2 (outside branch lines f=4,7)
        for f = 2, 3 do for r = -6, -1 do for y = TY - 1, TY + 2 do
            local k = (f * 5 + r * 3 + y * 7) % 10
            local name = "minecraft:iron_ore"
            if k == 0 then name = "minecraft:raw_iron_block"
            elseif k >= 7 then name = (k == 9) and "minecraft:granite" or "minecraft:tuff" end
            local p = H.setGrid(ctx, f, r, y, name)
            if name == "minecraft:raw_iron_block" then blocks[#blocks + 1] = { p = p, f = f, r = r, y = y } end
            if name == "minecraft:tuff" or name == "minecraft:granite" then filler[#filler + 1] = { p = p, f = f, r = r } end
        end end end
        -- one raw_iron_block directly adjacent to the main (f=5, r=1) on its own
        local lone = H.setGrid(ctx, 5, 1, TY, "minecraft:raw_iron_block")
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "run to DONE through a large vein")
        H.commonChecks(ctx)
        H.notNeedsHelp(ctx)
        for i, run in ipairs(H.excursions(ctx)) do
            H.check(#run <= VMAX + 1, "vein excursion %d dug %d blocks off the grid (VEIN_MAX=%d)", i, #run, VMAX)
        end
        -- vein mining only follows ore, so filler dug off the grid means it was treated as ore
        -- (a vein walk may still have to dig filler to reach the next ore; allow up to half)
        local fillerDug = 0
        for _, c in ipairs(filler) do
            if not H.onGrid(ctx, c.f, c.r) and H.wasDug(ctx, c.p.x, c.p.y, c.p.z) then fillerDug = fillerDug + 1 end
        end
        H.check(fillerDug <= #filler / 2, "%d of %d tuff/granite filler blocks were dug off the grid (treated as ore?)", fillerDug, #filler)
        if not H.wasDug(ctx, lone.x, lone.y, lone.z) then
            H.note("raw_iron_block next to the tunnel was NOT detected as ore (add raw_*_block to ORES?)")
        end
        return string.format("%d vein excursions, each <= VEIN_MAX", #H.excursions(ctx))
    end,
}
