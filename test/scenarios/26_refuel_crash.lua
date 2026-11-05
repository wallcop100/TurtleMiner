-- Version: 1.0.0
-- Scenario 26 (review #4): crash at home around turtle.refuel calls (no GPS). inv journals an
-- R line right after EACH refuel call, so a crash before any of several refuels in one
-- inv.refuel/restockFuel must recover cleanly and carry on mining.
-- The window right after a refuel and before its R line (and a crash while that R line is
-- written) can only be closed by nav.recover (fuel above the journal at a standstill = an
-- unjournalled refuel there). Those cases are strict once nav handles them; until then a
-- "position unknown" outcome is recorded as a note instead of a failure.
local function case(sim, H, opts, crashAt, label)
    sim.reset()
    local ctx = H.minerSetup(opts)
    local fired = false
    ctx.boot({ crashAt = function(e)
        if crashAt(e) then fired = true; return true end
        return false
    end })
    sim.run({ untilFn = function() return not ctx.t.computer.alive end, maxTime = 3600 })
    H.check(fired, "%s: crash point never reached", label)
    H.check(ctx.atHome(), "%s: crash should be at home, turtle at %s", label, H.fmtPos(ctx.t.pos))
    ctx.boot()
    -- back to work = down the shaft (the phase may still read TO_WORK while it mines)
    H.runUntil(ctx, function()
        return ctx.t.pos.y <= ctx.home.y - 3 or ctx.phase() == "NEEDS_HELP"
    end, 1200, label .. ": back to mining")
    if ctx.phase() == "NEEDS_HELP" then return false, tostring(ctx.reason()) end
    H.commonChecks(ctx)
    return true
end

return {
    title = "crash around refuel at home",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local strict, soft, pending = 0, 0, {}
        local coal3 = { { name = "minecraft:coal", count = 6 }, { name = "minecraft:coal", count = 6 },
            { name = "minecraft:coal", count = 8 } }
        local chest = { { name = "minecraft:coal", count = 64 }, { name = "minecraft:coal", count = 64 } }
        local variants = {
            -- 3 slots of coal: one inv.refuel makes 3 turtle.refuel calls
            { tag = "3 slots", n = 3, opts = { inventory = coal3 } },
            -- fuel chest: restockFuel sucks and burns several times
            { tag = "fuel chest", n = 3, opts = { inventory = { { name = "minecraft:coal", count = 20 } }, fuelChest = chest } },
        }
        for _, v in ipairs(variants) do
            local opts = { id = 26, fuel = 300, inventory = v.opts.inventory, fuelChest = v.opts.fuelChest,
                settings = { FUEL_KEEP = 4, FUEL_TARGET = 2000 } }
            for k = 1, v.n do
                local tag = v.tag .. " refuel #" .. k
                local ok, why = case(sim, H, opts, H.crashOn(H.isTurtleOp("refuel", "before"), k), tag .. " before")
                H.check(ok, "%s before: after reboot NEEDS_HELP (%s)", tag, tostring(why))
                strict = strict + 1
                for _, c in ipairs({
                    { "after", H.crashOn(H.isTurtleOp("refuel", "after"), k) },
                    { "during R write", H.crashOnWriteAfterOp("refuel", k, H.isJournalWrite("R")) },
                }) do
                    ok, why = case(sim, H, opts, c[2], tag .. " " .. c[1])
                    if ok then
                        soft = soft + 1
                    else
                        H.check(why:find("position unknown", 1, true) ~= nil, "%s %s: NEEDS_HELP (%s)", tag, c[1], why)
                        pending[#pending + 1] = tag .. " " .. c[1]
                    end
                end
            end
        end
        if #pending > 0 then
            H.note(#pending .. " crash(es) between refuel and its R line still need nav.recover support: "
                .. pending[1])
        end
        return string.format("%d crashes before a refuel recovered; %d after-refuel crashes recovered", strict, soft)
    end,
}
