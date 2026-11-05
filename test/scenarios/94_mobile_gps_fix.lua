-- Version: 1.0.0
-- Scenario 94 (AR-G): mobile GPS. a) A turtle at depth with no GPS hosts at all gets an exact
-- fix from 4 working turtles that know their world position (different heights/positions).
-- b) A host that is lost, or mid-move, does not answer: with only 3 usable hosts there is no fix.
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }

-- A turtle running state + nav + net (+ gpsmobile through net), as a program on its disk.
-- _G.HOST.st is its state, HOST.mid records what gpsmobile says from inside a move
-- (answers / silent), HOST.doMove makes it move up.
local HOST_SRC = [==[
local cfg = textutils.unserialize(fs.open("host.cfg", "r").readAll())
local state, nav, net = require("state"), require("nav"), require("net")
local gm = require("gpsmobile")
local st = state.new(cfg.pos, 1, true)
local HOST = { st = st, mid = {} }
_G.HOST = HOST
nav.init(st, { shouldAbort = function() return false end, onMove = function() end, save = function() return true end })
local realUp = turtle.up
turtle.up = function() HOST.mid[#HOST.mid + 1] = gm.position() and "answers" or "silent"; return realUp() end
net.init({ STATUS_INTERVAL = 10 })
parallel.waitForAny(function()
    net.run(function() return { label = "H", phase = "MINING", pos = st.pos, gpsHost = net.gpsHost() } end)
end, function()
    while true do
        if HOST.doMove then HOST.doMove = false; HOST.moved = nav.up() end
        sleep(0.5)
    end
end)
]==]

local function host(sim, w, id, pos)
    local t = sim.turtle(w, { id = id, pos = pos, equip = BASIC })
    t.fs:write("host.lua", HOST_SRC)
    t.fs:write("host.cfg", sim.textutils.serialize({ pos = { x = pos.x, y = pos.y, z = pos.z } }))
    sim.boot(t, { "host" }, { background = true })
    return t
end

return {
    title = "mobile GPS: fix from 4 working turtles at depth; lost and mid-move turtles stay silent",
    needs = { "net", "nav", "state" },
    run = function(sim, H)
        H.rawGps({})
        local w = sim.world()
        local P = { { 10, 40, 0 }, { -12, 52, 8 }, { 6, 35, -14 }, { -4, 60, 12 } }
        local hs = {}
        for i, p in ipairs(P) do hs[i] = host(sim, w, 10 + i, { x = p[1], y = p[2], z = p[3] }) end
        local obs = sim.turtle(w, { id = 77, pos = { x = 0, y = 20, z = 0 }, equip = BASIC })
        local oc = H.netTurtle(obs, "Observer")
        sim.run({ maxTime = 3 })
        local function locate()
            oc.jobs[#oc.jobs + 1] = function(net, G)
                local x, y, z = G.gps.locate(2)
                return x and string.format("%d,%d,%d", x, y, z) or "none"
            end
            sim.run({ maxTime = 6 })
            return oc.results[#oc.results]
        end
        local want = "0,20,0"
        local n0 = #sim.net.gpsAnswers
        local r = locate()
        H.check(r == want, "(a) fix %s want %s (answers heard %d)", tostring(r), want, #sim.net.gpsAnswers - n0)

        -- b) a lost host is silent: only 3 left -> no fix
        hs[4].computer.env.HOST.st.lost = "test"
        n0 = #sim.net.gpsAnswers
        r = locate()
        H.check(r == "none", "(b) fix %s although a host is lost", tostring(r))
        for i = n0 + 1, #sim.net.gpsAnswers do
            H.check(sim.net.gpsAnswers[i].from ~= 14, "(b) lost turtle #14 replied")
        end
        hs[4].computer.env.HOST.st.lost = nil
        r = locate()
        H.check(r == want, "(b) no fix after the host recovered: %s", tostring(r))

        -- b2) inside a real move (between intent and done) gpsmobile says nothing, afterwards it does
        local c1 = hs[1].computer.env.HOST
        c1.doMove = true
        sim.run({ maxTime = 3 })
        H.check(c1.moved, "host did not move")
        H.check(c1.mid[1] == "silent", "host answered mid-move: %s", tostring(c1.mid[1]))
        return "exact fix from 4 working turtles; lost and mid-move hosts stay silent"
    end,
}
