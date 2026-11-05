-- Version: 1.0.0
-- Scenario 15: the main tunnel runs through an amethyst geode (smooth_basalt, calcite,
-- amethyst_block, budding_amethyst, hollow inside) and pointed dripstone that falls
-- when its support is dug (like gravel). No stuck; geode blocks are not ore (not
-- vein-mined); reports which geode/dripstone items are missing from cfg.TRASH.
local GEODE = { "minecraft:smooth_basalt", "minecraft:calcite", "minecraft:amethyst_block", "minecraft:budding_amethyst" }
return {
    title = "geodes and dripstone",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local defaults = H.configDefaults()
        local missing = {}
        for _, n in ipairs({ "minecraft:smooth_basalt", "minecraft:calcite", "minecraft:amethyst_block",
                             "minecraft:pointed_dripstone", "minecraft:dripstone_block", "minecraft:amethyst_shard" }) do
            if not H.inList(defaults.TRASH, n) then missing[#missing + 1] = n:gsub("^minecraft:", "") end
        end
        local ctx = H.minerSetup({ id = 15, settings = { MAX_CORRIDORS = 1, MAIN_LENGTH = 12 } })
        local TY = ctx.worldTargetY
        local w = ctx.w
        -- geode centred on the main at f=5..9, r=-2..2, y TY-2..TY+2: shell layers by distance
        local offLine = {}
        for f = 5, 9 do
            for r = -2, 2 do
                for y = TY - 2, TY + 2 do
                    local d = math.max(math.abs(f - 7), math.abs(r), math.abs(y - TY))
                    local name = ({ [0] = "air", [1] = "minecraft:amethyst_block", [2] = "minecraft:calcite" })[d]
                    if d == 1 and (f + r + y) % 3 == 0 then name = "minecraft:budding_amethyst" end
                    local p = H.setGrid(ctx, f, r, y, name)
                    if name ~= "air" and math.abs(r) >= 2 and not H.onGrid(ctx, f, r) then offLine[#offLine + 1] = p end
                end
            end
        end
        for f = 4, 10 do for r = -3, 3 do
            local p = H.gridToWorld(ctx, f, r, TY + 3)
            if w:get(p.x, p.y, p.z) == "minecraft:stone" then w:set(p.x, p.y, p.z, "minecraft:smooth_basalt") end
        end end
        -- dripstone hanging over the main at f=3 (support at TY+2, tip at TY+1 and TY)
        H.setGrid(ctx, 3, 0, TY + 2, "minecraft:dripstone_block")
        H.setGrid(ctx, 3, 0, TY + 1, "minecraft:pointed_dripstone")
        H.setGrid(ctx, 3, 0, TY, "minecraft:pointed_dripstone")
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "run to DONE through geode and dripstone")
        H.commonChecks(ctx)
        H.notNeedsHelp(ctx)
        local vein = 0
        for _, p in ipairs(offLine) do if H.wasDug(ctx, p.x, p.y, p.z) then vein = vein + 1 end end
        H.check(vein == 0, "%d geode blocks away from the tunnel were dug (treated as ore?)", vein)
        local dug = H.dugSet(ctx, TY)
        H.check(dug["11:0"] or dug["12:0"], "main did not continue past the geode")
        if #missing > 0 then H.note("not in cfg.TRASH: " .. table.concat(missing, ", ")) end
        return "geode passed, not vein-mined"
    end,
}
