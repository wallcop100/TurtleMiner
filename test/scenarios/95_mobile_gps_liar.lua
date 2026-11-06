-- Version: 1.0.0
-- Scenario 95 (AR-G): a lying GPS host set (wrong coordinates, 20 blocks off) can't shift a
-- turtle whose journal position is trusted: nav.gpsLocate rejects a fix more than 2 blocks away
-- and logs it once. A lost turtle (journal not trusted) takes the fix; an honest fix within 2
-- blocks of the journal is accepted.
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }

local SRC = [==[
local state, nav, net = require("state"), require("nav"), require("net")
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
        H.done = true
    end
    sleep(0.2)
end
]==]

return {
    title = "mobile GPS: lying hosts cannot shift a turtle with a trusted journal",
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

        sim.gpsHosts = hosts(0)
        local r = ask()
        H.check(r == "5,30,5", "honest fix %s", tostring(r))

        sim.gpsHosts = hosts(20)
        r = ask()
        H.check(r == "none", "lying hosts shifted a trusted turtle: %s", tostring(r))
        r = ask()
        H.check(r == "none", "second lie accepted: %s", tostring(r))
        local n = 0
        for _, l in ipairs(h.log) do if l:find("disagrees with journal", 1, true) then n = n + 1 end end
        H.check(n == 1, "disagreement logged %d times, want once: %s", n, table.concat(h.log, " | "))

        sim.gpsHosts = hosts(1)       -- honest within 2 blocks: accepted
        r = ask()
        H.check(r == "5,30,5" or r == "6,30,5" or r == "4,30,5", "close fix rejected: %s", tostring(r))

        h.st.lost = "test"            -- journal not trusted: the fix is taken
        sim.gpsHosts = hosts(20)
        r = ask()
        H.check(r ~= "none" and r ~= "5,30,5", "lost turtle did not take the fix: %s", tostring(r))
        return "journal-trusted turtle rejects a 20-block lie (logged once); lost turtle takes the fix"
    end,
}
