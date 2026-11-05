-- Version: 1.0.0
-- Scenario 87 (AR-T): the level is deeper than a basic modem reaches (70 blocks). A: basic
-- modems only, no relay: the up trip uses timed slots booked before leaving (slot_req/slot);
-- nobody collides. B: an ender relay at the shaft bottom: live seg_req/seg_grant from depth, no
-- slots needed. SKIPs until the army modules exist.
return {
    title = "army: basic modems use timed slots; a relay at the shaft bottom gives live reservations",
    needs = { "net", "mine", "miner" },
    run = function(sim, H)
        local A = require("army")(sim, H)
        A.need({ "servers/relay.lua" })
        local function run(withRelay)
            sim.reset()
            sim.net.modemEvents = true
            A.counts, A.list, A.tapped = {}, {}, false
            A.tap()
            local st = A.station({ y = 70, shaftTo = -2 })
            local ld, ui = A.leader(st, { kind = "basic" }), A.ui()
            local rec = A.newArmy(st, ld, ui, { name = "deep", ores = { "lapis" } })   -- level 0: 70 below the station
            if withRelay then A.relay(st.shaftCell(1, 1), "ender", 200) end
            A.joinTurtles(st, ld, "deep", 4, { equip = A.BASIC })
            A.runUntil(st, function() return A.done(rec) >= 4 end, 9000, (withRelay and "relay" or "slots") .. ": 4 branches done")
            A.assertClean(st, withRelay and "with relay" or "basic only")
            return A.kinds(), A.done(rec)
        end
        local k1, d1 = run(false)
        H.check((k1.slot_req or 0) > 0 and (k1.slot or 0) > 0, "basic modems only: no timed slots used (slot_req %d, slot %d)", k1.slot_req or 0, k1.slot or 0)
        local s1 = k1.slot
        local k2, d2 = run(true)
        H.check((k2.seg_req or 0) > 0 and (k2.seg_grant or 0) > 0, "relay: no live reservations")
        H.check((k2.slot or 0) < s1, "relay: still %d slots (basic-only run: %d)", k2.slot or 0, s1)
        return string.format("basic only: %d slot_req/%d slot, %d branches; relay: %d seg_req, %d slot, %d branches; 0 collisions both",
            k1.slot_req or 0, s1, d1, k2.seg_req or 0, k2.slot or 0, d2)
    end,
}
