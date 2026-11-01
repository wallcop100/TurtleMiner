-- Version: 1.1.0
-- Scenario 10: servers/central_monitor.lua on a pocket computer (`pocket` defined,
-- 26x20 term that records any write past the edge) renders a fleet message.
return {
    title = "pocket monitor layout",
    needs = {},
    run = function(sim, H)
        local path = os.getenv("SIM_MONITOR_FILE") or (sim.REPO .. "/servers/central_monitor.lua")
        local f = io.open(path, "rb")
        if not f then H.skip("servers/central_monitor.lua missing") end
        local src = f:read("a")
        f:close()
        if not src:find("TMINER", 1, true) then
            H.skip("servers/central_monitor.lua does not speak TMINER yet (WP-D pending)")
        end
        local p = sim.computer({ id = 50, label = "pocket", pocket = true, strictTerm = true, modem = "back" })
        H.installServer(p)   -- central_monitor.lua is a launcher for tminer_server + tm_*.lua
        local srv = H.server({ id = 100 })
        local function st(id, label, phase, reason, alert)
            return { v = 1, kind = "status", from = id, id = id, to = "server", label = label, version = "1.0.0", phase = phase,
                reason = reason, pos = { x = 12, y = -58, z = -40 }, facing = 1, home = { x = 0, y = 64, z = 0 },
                gps = true, fuel = 1234, fuelNeeded = 300, slotsUsed = 7,
                job = { corridor = 1, branch = 3, side = "L", step = 12 },
                stats = { ores = 42, blocks = 900, trips = 3, uptime = 3600 }, cfg = { targetY = -58, focus = "all" },
                lastSeen = math.floor(sim.BASE_EPOCH + sim.now * 1000), alert = alert }
        end
        sim.boot(p, { "central_monitor" }, { background = true })
        for _ = 1, 4 do
            sim.run({ maxTime = 5, untilFn = function() return not p.alive end })
            srv.fleet({ st(41, "Alpha", "MINING"), st(42, "Bravo", "NEEDS_HELP", "chest full", "NEEDS_HELP") })
        end
        sim.run({ maxTime = 5, untilFn = function() return not p.alive end })
        H.check(p.alive, "monitor stopped on the pocket: %s %s", p.status, tostring(p.err):sub(1, 500))
        local text = p.term._text()
        local v = p.term._violations
        H.check(#v == 0, "%d writes past the 26x20 screen, first at (%d,%d): %q", #v, v[1] and v[1].x or 0, v[1] and v[1].y or 0,
            v[1] and v[1].text or "")
        for _, who in ipairs({ { 41, "Alpha" }, { 42, "Bravo" } }) do
            H.check(text:find(who[2], 1, true) or text:find("%f[%d]" .. who[1] .. "%f[%D]"),
                "turtle %s (#%d) not shown on the pocket screen:\n%s", who[2], who[1], text)
        end
        return "rendered:\n" .. text
    end,
}
