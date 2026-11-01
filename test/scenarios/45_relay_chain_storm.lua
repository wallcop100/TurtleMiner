-- Version: 1.0.0
-- Scenario 45 (CM-5): turtle-to-turtle relaying with basic modems (64 blocks).
--  A: chain of 4 basic turtles, each ~50 blocks from the next, only the first in reach of the
--     basic-modem server: hops 1..4 are learned, every status reaches the monitor and a command
--     to the last one is acked through the chain.
--  B: no broadcast storm: 10 basic turtles in one cluster at depth, some in reach of the server.
--     Each relays only when it moves a message closer (dedupe, hop limit, random delay with
--     suppression). Transmissions per original message stay small (bounded), compared with
--     RELAY=on everywhere (plain flooding).
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }

local function count(sim, ids, t0)
    local orig, relays = 0, 0
    for _, e in ipairs(sim.net.log) do
        if ids[e.from] and e.time >= t0 and type(e.msg) == "table" then
            if e.msg.from == e.from and (e.msg.hops or 0) == 0 then orig = orig + 1 else relays = relays + 1 end
        end
    end
    return orig, relays
end

local function cluster(sim, H, relaySetting)
    sim.reset()
    local w = sim.world()
    local srv = H.monitorComputer({ pos = { x = 0, y = 42, z = 3 }, modemKind = "basic" })
    local ids, ts = {}, {}
    for i = 1, 10 do
        local p = { x = (i - 1) * 6 - 27, y = -(i % 3) * 10, z = 30 + (i % 2) * 10 }
        local t = sim.turtle(w, { id = i, pos = p, equip = BASIC })
        if relaySetting then H.writeSettings(t, { RELAY = relaySetting }) end
        H.netOnly(t)
        ids[i] = true
        ts[i] = t
    end
    sim.run({ maxTime = 60 })               -- learn hops
    local t0 = sim.now
    sim.run({ maxTime = 300 })
    local orig, relays = count(sim, ids, t0)
    local nowMs = sim.BASE_EPOCH + sim.now * 1000
    local heard, inRange = 0, 0
    for i = 1, 10 do
        local r = srv.rec(i)
        if r and nowMs - r.lastSeen < 15000 then heard = heard + 1 end
        if ts[i].computer.net.hop() == 1 then inRange = inRange + 1 end
    end
    return { orig = orig, relays = relays, heard = heard, direct = inRange,
             srvRelays = select(2, count(sim, { [100] = true }, t0)) }
end

return {
    title = "turtle relay chain, no broadcast storm",
    needs = { "net" },
    run = function(sim, H)
        -- A: chain ---------------------------------------------------------------------
        local w = sim.world()
        local srv = H.monitorComputer({ pos = { x = 0, y = 42, z = 3 }, modemKind = "basic" })
        local chain = {}
        for i = 1, 4 do
            local t = sim.turtle(w, { id = i, pos = { x = (i - 1) * 50, y = -(i - 1) * 10, z = 0 }, equip = BASIC })
            H.netOnly(t)
            chain[i] = t
        end
        sim.run({ maxTime = 90 })
        local nowMs = sim.BASE_EPOCH + sim.now * 1000
        for i, t in ipairs(chain) do
            local hop = t.computer.net.hop()
            H.check(hop == i, "A: turtle %d at %s has hop %s, want %d", i, H.fmtPos(t.pos), tostring(hop), i)
            local r = srv.rec(i)
            H.check(r and nowMs - r.lastSeen < 15000, "A: monitor does not hear turtle %d (hop %d)", i, i)
        end
        local id = srv.M.issueCmd(4, "PAUSE")
        sim.run({ maxTime = 10, untilFn = function() return srv.M.S.pending[id] == nil end })
        local c = srv.rec(4).cmd
        H.check(c.state == "ok", "A: PAUSE to the end of the chain: %s %s", tostring(c.state), tostring(c.err))

        -- B: cluster of 10 -------------------------------------------------------------------
        local auto = cluster(sim, H, nil)
        H.check(auto.heard == 10, "B: monitor hears %d of 10 turtles", auto.heard)
        H.check(auto.direct >= 1 and auto.direct < 10, "B: %d of 10 in direct reach (want a mix)", auto.direct)
        local perMsg = (auto.orig + auto.relays) / auto.orig
        H.check(perMsg <= 2.5, "B: %.2f transmissions per original message (%d orig, %d relays): storm",
            perMsg, auto.orig, auto.relays)
        local flood = cluster(sim, H, "on")
        H.check(flood.heard == 10, "B: RELAY=on: monitor hears %d of 10", flood.heard)
        return string.format("A: chain hops 1-4, cmd acked via 3 relays; B (300 s, 10 turtles, %d direct): auto %d orig + %d relays"
            .. " (%.2f per msg, server relayed %d); RELAY=on %d orig + %d relays (%.2f per msg)",
            auto.direct, auto.orig, auto.relays, perMsg, auto.srvRelays, flood.orig, flood.relays,
            (flood.orig + flood.relays) / flood.orig)
    end,
}
