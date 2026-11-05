-- Version: 1.0.0
-- Scenario 27 (review #6, #4): inv.refuel keeps FUEL_KEEP items in reserve, but
-- inv.refuel(target, {emergency = true}) burns the reserve too (stranded turtle).
-- Every turtle.refuel call is followed by its own R journal line.
return {
    title = "emergency refuel burns the reserve; R line per refuel",
    needs = { "config", "state", "nav", "inv" },
    run = function(sim, H)
        local ctx = H.mineDriver({ fuel = 10, noMineInit = true, settings = { FUEL_KEEP = 4 },
            inventory = { { name = "minecraft:coal", count = 2 }, { name = "minecraft:coal", count = 2 } } })
        local r = ctx.run([[
            local a = inv.refuel(500)
            local items = inv.fuelItemCount()
            local b = inv.refuel(500, { emergency = true })
            local rs = 0
            for _, e in ipairs(state.readJournal()) do if e.tag == "R" then rs = rs + 1 end end
            return a, items, b, rs, inv.fuelItemCount()
        ]])
        local a, items, b, rs, left = table.unpack(r.ret)
        H.check(a == 10 and items == 4, "normal refuel must keep the %d-item reserve: fuel %s, items %s",
            4, tostring(a), tostring(items))
        H.check(b == 330, "emergency refuel should burn all 4 coal (fuel 330), got %s", tostring(b))
        H.check(left == 0, "emergency refuel left %s fuel items", tostring(left))
        H.check(rs == 2, "expected one R line per turtle.refuel call (2), journal has %s", tostring(rs))
        H.check(ctx.t.fuel == 330, "world fuel %s", tostring(ctx.t.fuel))
        return "reserve kept normally, burned in emergency (fuel " .. b .. "), " .. rs .. " R lines"
    end,
}
