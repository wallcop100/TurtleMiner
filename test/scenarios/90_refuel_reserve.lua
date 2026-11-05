-- Version: 1.0.0
-- Scenario 90 (user report): at home with too little fuel to leave, only the FUEL_KEEP
-- reserve of coal on board and no fuel chest. The turtle must burn the reserve and go,
-- not sit in "refuelling" / NEEDS_HELP with the old fuel level.
return {
    title = "refuel at home burns the reserve; unknown fuels via refuel(0)",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        -- A: 10 coal (below FUEL_KEEP 16), fuel 30: not enough to leave without the coal.
        local m = H.minerSetup({ id = 90, fuel = 30, settings = { FUEL_KEEP = 16, MAX_CORRIDORS = 1 },
            inventory = { { name = "minecraft:coal", count = 10 } } })
        m.boot()
        H.runUntil(m, function() return m.phase() == "TO_WORK" end, 1800, "A: leaves home after burning the reserve")
        H.check(m.t.fuel > 30, "A: fuel did not go up (%s)", tostring(m.t.fuel))
        -- B: no fuel at all: NEEDS_HELP, then coal appears in its inventory and it carries on.
        sim.reset()
        m = H.minerSetup({ id = 91, fuel = 5, settings = { MAX_CORRIDORS = 1, HELP_RETRY = 10 } })
        m.boot()
        H.runUntil(m, function() return m.phase() == "NEEDS_HELP" end, 1800, "B: NEEDS_HELP with no fuel")
        H.check(tostring(m.reason()):find("carrying 0", 1, true), "B: reason lacks carried count: %s", tostring(m.reason()))
        m.t.inv[5] = { name = "minecraft:coal", count = 20 }
        H.runUntil(m, function() return m.phase() == "TO_WORK" end, 600, "B: carries on once coal is added")
        return "reserve burned at home; NEEDS_HELP recovers when coal is added"
    end,
}
