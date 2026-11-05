-- Version: 1.0.0
-- Scenario 25 (review #3, #20): storage next to home that peripheral can't see, or an
-- inventory that isn't storage.
--   A: dump chest on the equipped-modem side (left), fuel chest on top: loot goes into the
--      modem-side chest (found by inspect), never into the fuel chest.
--   B: dump behind, fuel chest on the modem side: the unlistable chest can't be told apart,
--      so the dump is the one behind and nothing but fuel ever goes into the left chest.
--   C: a furnace (an inventory peripheral) behind, the chest on the pickaxe side: the furnace
--      is ignored, loot goes into the chest.
local function nonFuel(w, p)
    local n = 0
    for _, it in pairs(w:chestContents(p.x, p.y, p.z) or {}) do
        if it.name ~= "minecraft:coal" then n = n + it.count end
    end
    return n
end

local function run(sim, H, opts, extra)
    sim.reset()
    local ctx = H.minerSetup(opts)
    if extra then extra(ctx) end
    local TY = ctx.worldTargetY
    ctx.w:set(0, TY, -5, "minecraft:diamond_ore")
    ctx.boot()
    H.runUntil(ctx, H.doneAtHome(ctx, 10), 4 * 3600, "DONE at home")
    H.commonChecks(ctx)
    H.notNeedsHelp(ctx)
    return ctx
end

return {
    title = "chest on modem side / non-storage inventory",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local coal = { { name = "minecraft:coal", count = 64 } }
        local base = { MAX_CORRIDORS = 1 }

        -- A
        local ctx = run(sim, H, { id = 25, fuel = 3000, chestSide = "left", fuelChest = coal, settings = base })
        local cp, fp = ctx.chestPos, ctx.fuelChestPos
        H.check(ctx.w:chestCount(cp.x, cp.y, cp.z, "minecraft:diamond") >= 1,
            "A: loot not in the modem-side chest (has %d items)", ctx.w:chestCount(cp.x, cp.y, cp.z))
        H.check(nonFuel(ctx.w, fp) == 0, "A: %d loot items went into the fuel chest", nonFuel(ctx.w, fp))
        local a = ctx.w:chestCount(cp.x, cp.y, cp.z)

        -- B
        ctx = run(sim, H, { id = 25, fuel = 3000, fuelChestSide = "left", fuelChest = coal, settings = base })
        cp, fp = ctx.chestPos, ctx.fuelChestPos
        H.check(ctx.w:chestCount(cp.x, cp.y, cp.z, "minecraft:diamond") >= 1, "B: loot not in the chest behind")
        H.check(nonFuel(ctx.w, fp) == 0, "B: %d loot items went into the modem-side fuel chest", nonFuel(ctx.w, fp))

        -- C
        local furnace
        ctx = run(sim, H, { id = 25, fuel = 3000, chestSide = "right", settings = base }, function(c)
            furnace = c.sidePos("back")
            c.w:chest(furnace.x, furnace.y, furnace.z, {}, { name = "minecraft:furnace", size = 3 })
        end)
        cp = ctx.chestPos
        H.check(ctx.w:chestCount(furnace.x, furnace.y, furnace.z) == 0, "C: items were put into the furnace")
        H.check(ctx.w:chestCount(cp.x, cp.y, cp.z, "minecraft:diamond") >= 1, "C: loot not in the chest on the right")
        return string.format("A: %d items in modem-side dump, fuel chest clean; B, C ok", a)
    end,
}
