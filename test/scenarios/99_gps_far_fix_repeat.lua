-- Version: 1.0.0
-- Scenario 99: a turtle whose journal is off by more than 2 blocks gets corrected. One or two
-- fixes that disagree are rejected (scenario 95), but FAR_REPEAT (3) fixes in a row at the
-- same offset are taken. Mobile GPS: a turtle only answers pings once a fix confirmed its
-- position, and stops while a fix disagrees.
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }

local SRC = [==[
local state, nav, net = require("state"), require("nav"), require("net")
local gm = require("gpsmobile")
local st = state.new({ x = 5, y = 30, z = 5 }, 1, true)
st.phase = "MINING"
local H = { st = st, log = {} }
_G.HOST = H
nav.init(st, { shouldAbort = function() return false end, onMove = function() end, save = function() return true end,
    onEvent = function(level, text) H.log[#H.log + 1] = tostring(text) end })
net.init({ STATUS_INTERVAL = 10 })
while true do
    if H.ask then
        H.ask = false
        local p = nav.gpsLocate(true)
        H.fix = p and (p.x .. "," .. p.y .. "," .. p.z) or "none"
        if p then st.pos = p end
        H.hosts = gm.position() ~= nil
        H.done = true
    end
    sleep(0.2)
end
]==]

return {
    title = "far GPS fix taken after 3 matching repeats; mobile GPS only from a confirmed position",
    needs = { "nav", "state", "net" },
    run = function(sim, H)
        H.rawGps({})
        local w = sim.world()
        local t = sim.turtle(w, { id = 5, pos = { x = 5, y = 30, z = 5 }, equip = BASIC })
        t.fs:write("host.lua", SRC)
        sim.boot(t, { "host" }, { background = true })
        sim.run({ maxTime = 1 })
        local h = t.computer.env.HOST
        local function ask()
            h.done, h.ask = false, true
            sim.run({ maxTime = 8 })
            H.check(h.done, "gpsLocate did not finish")
            return h.fix
        end
        local function hosts(off)
            local r = {}
            for i, d in ipairs({ { 30, 0, 0 }, { -30, 10, 5 }, { 5, 25, -30 }, { 0, -20, 40 } }) do
                local p = { x = 5 + d[1], y = 30 + d[2], z = 5 + d[3] }
                r[i] = { pos = p, says = { x = p.x + off, y = p.y, z = p.z }, kind = "ender" }
            end
            return r
        end

        H.check(not h.st.fixOk, "fresh state already marked confirmed")
        sim.gpsHosts = hosts(0)
        H.check(ask() == "5,30,5", "honest fix")
        H.check(h.hosts, "confirmed turtle does not host mobile GPS")

        -- the journal is wrong by 10 (the GPS is right): two rejections, then accepted
        h.st.pos = { x = -5, y = 30, z = 5 }
        H.check(ask() == "none", "first far fix accepted")
        H.check(not h.hosts, "turtle hosts while a fix disagrees")
        H.check(ask() == "none", "second far fix accepted")
        local r = ask()
        H.check(r == "5,30,5", "third matching far fix rejected: %s", tostring(r))
        H.check(h.hosts, "corrected turtle does not host")
        local ok = false
        for _, l in ipairs(h.log) do if l:find("repeated 3 times", 1, true) then ok = true end end
        H.check(ok, "no correction log line: %s", table.concat(h.log, " | "))

        -- far fixes that don't agree with each other never count up
        h.st.pos = { x = 5, y = 30, z = 5 }
        for i, off in ipairs({ 20, -20, 20, -20 }) do
            sim.gpsHosts = hosts(off)
            H.check(ask() == "none", "inconsistent far fix %d accepted", i)
        end
        return "2 far fixes rejected, 3rd matching one corrects the journal; hosting only when confirmed"
    end,
}
