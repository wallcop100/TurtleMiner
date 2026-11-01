-- Version: 1.0.0
-- Scenario 44 (CM-5): mixed modems, all detected at runtime (no settings anywhere).
--  A: basic-modem server at the surface + one ender-modem relay computer (servers/relay.lua)
--     far away: basic-modem turtles at depth, out of the server's range, are in contact
--     (hop 2), their status reaches the monitor and commands are acked at once. The relay
--     works out that its modem is an ender modem (it hears basic modems > 400 blocks away).
--  B: one ender-modem turtle anywhere acts as the hub instead of the relay computer.
--  C: ender-modem server alone: contact everywhere (hop 1).
--  D: GPS replies obey the same rule: basic-modem hosts at the surface give no fix at depth,
--     ender-modem hosts do.
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }
local ENDER = { left = "computercraft:wireless_modem_advanced", right = "minecraft:diamond_pickaxe" }
local DEEP = { { x = 0, y = -40, z = 0 }, { x = 60, y = -50, z = 60 }, { x = -100, y = -55, z = 30 } }

local function turtles(sim, H, w, firstId, equipFor)
    local ts = {}
    for i, p in ipairs(DEEP) do
        local t = sim.turtle(w, { id = firstId + i - 1, pos = p, equip = equipFor and equipFor(i) or BASIC })
        H.netOnly(t)
        ts[#ts + 1] = t
    end
    sim.run({ maxTime = 0.1 })
    return ts
end

local function inContact(sim, H, srv, ts, what, wantHop)
    sim.run({ maxTime = 60 })
    local M = srv.M
    local nowMs = sim.BASE_EPOCH + sim.now * 1000
    for _, t in ipairs(ts) do
        local r = srv.rec(t.id)
        H.check(r and nowMs - r.lastSeen < 15000, "%s: monitor does not hear turtle %d at %s", what, t.id, H.fmtPos(t.pos))
        local net = t.computer.net
        H.check(net.inContact(), "%s: turtle %d thinks it is out of contact", what, t.id)
        if wantHop then
            H.check(net.hop() == wantHop, "%s: turtle %d hop %s, want %d", what, t.id, tostring(net.hop()), wantHop)
        end
        local id = M.issueCmd(t.id, "REQUEST_STATUS")
        H.check(not M.S.pending[id].queued, "%s: command to turtle %d queued although in contact", what, t.id)
        sim.run({ maxTime = 5, untilFn = function() return M.S.pending[id] == nil end })
        H.check(r.cmd.state == "ok", "%s: REQUEST_STATUS to %d: %s %s", what, t.id, tostring(r.cmd.state), tostring(r.cmd.err))
    end
end

return {
    title = "mixed modems: ender relay / ender turtle / ender server",
    needs = { "net" },
    needsFile = "servers/relay.lua",
    run = function(sim, H)
        local relaySrc
        do
            local f = assert(io.open(sim.REPO .. "/servers/relay.lua", "rb"))
            relaySrc = f:read("a")
            f:close()
        end
        -- A0: basic server alone: the deep turtles are out of range ------------------------
        local w = sim.world()
        local srv = H.monitorComputer({ pos = { x = 0, y = 42, z = 3 }, modemKind = "basic" })
        local ts = turtles(sim, H, w, 1)
        sim.run({ maxTime = 60 })
        for _, t in ipairs(ts) do
            H.check(srv.rec(t.id) == nil, "A0: monitor heard turtle %d at %s (out of range)", t.id, H.fmtPos(t.pos))
            H.check(not t.computer.net.inContact(), "A0: turtle %d thinks it is in contact", t.id)
        end
        local q = srv.M.issueCmd(1, "PAUSE")
        H.check(srv.M.S.pending[q].queued, "A0: command to an unheard turtle not queued")

        -- A: basic server + ender relay computer ---------------------------------------
        sim.reset()
        sim.net.modemEvents = true          -- modem_message carries the distance (CC does)
        w = sim.world()
        srv = H.monitorComputer({ pos = { x = 0, y = 42, z = 3 }, modemKind = "basic" })
        local relay = sim.computer({ id = 200, pos = { x = 500, y = 100, z = -800 }, modemKind = "ender" })
        relay.fs:write("relay.lua", relaySrc)
        sim.boot(relay, { "relay" }, { background = true })
        ts = turtles(sim, H, w, 1)
        for _, t in ipairs(ts) do
            H.check(t.computer.net.modemKind() == "basic", "A: turtle %d detected modem %s", t.id, t.computer.net.modemKind())
        end
        inContact(sim, H, srv, ts, "A", 2)
        H.check(relay.alive, "A: relay stopped: %s", tostring(relay.err))
        local rtext = relay.term._text()
        H.check(rtext:find("modem ender", 1, true), "A: relay did not detect its ender modem:\n%s", rtext)
        H.check(rtext:find("server 1 hop", 1, true), "A: relay screen has no hop line:\n%s", rtext)
        local a = srv.M.S.turtles[1].st.label

        -- B: basic server + one ender turtle at depth ---------------------------------
        sim.reset()
        w = sim.world()
        srv = H.monitorComputer({ pos = { x = 0, y = 42, z = 3 }, modemKind = "basic" })
        ts = turtles(sim, H, w, 1, function(i) return i == 3 and ENDER or BASIC end)
        H.check(ts[3].computer.net.modemKind() == "ender", "B: ender turtle detected %s", ts[3].computer.net.modemKind())
        inContact(sim, H, srv, ts, "B")
        H.check(ts[3].computer.net.stats.relayed > 0, "B: the ender turtle relayed nothing")

        -- C: ender server alone ------------------------------------------------------------
        sim.reset()
        w = sim.world()
        srv = H.monitorComputer({ pos = { x = 0, y = 42, z = 3 }, modemKind = "ender" })
        ts = turtles(sim, H, w, 1)
        inContact(sim, H, srv, ts, "C", 1)
        local relayedC = 0
        for _, t in ipairs(ts) do relayedC = relayedC + t.computer.net.stats.relayed end
        H.check(relayedC == 0, "C: basic turtles relayed %d messages with an ender server in reach of all", relayedC)

        -- D: GPS ----------------------------------------------------------------------------
        local function locate(kind)
            sim.reset()
            local wd = sim.world()
            sim.gpsHosts = {}
            for _, p in ipairs({ { 20, 90, 0 }, { -20, 90, 0 }, { 0, 90, 20 }, { 0, 100, -20 } }) do
                sim.gpsHosts[#sim.gpsHosts + 1] = { pos = { x = p[1], y = p[2], z = p[3] }, kind = kind }
            end
            local t = sim.turtle(wd, { id = 9, pos = { x = 10, y = -50, z = 10 }, equip = BASIC })
            local fix
            sim.boot(t, function(G) fix = { G.gps.locate(2) } end, { maxTime = 10 })
            sim.gpsHosts = nil
            return fix and fix[1] ~= nil
        end
        H.check(not locate("basic"), "D: GPS fix at Y -50 from basic-modem hosts at Y 90")
        H.check(locate("ender"), "D: no GPS fix at Y -50 from ender-modem hosts")
        return "A0 basic only: no contact, cmds queued; A ender relay: 3 deep basic turtles hop 2, relay detected ender; B ender turtle hub; C ender server hop 1, 0 turtle relays; D GPS by modem kind (" .. tostring(a) .. ")"
    end,
}
