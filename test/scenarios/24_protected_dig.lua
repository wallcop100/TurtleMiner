-- Version: 1.0.0
-- Scenario 24 (review #10): nav moves never dig protected blocks (chest, barrel, shulker,
-- computercraft/turtle) and goTo(home) never falls back to a climb-first order.
local GOHOME_SRC = [==[
local state = require("state")
local nav = require("nav")
local st = state.load()
nav.init(st, { shouldAbort = function() return false end, onMove = function() end,
    save = function() return state.save(st) end })
assert(nav.recover(st))
local ok, why = nav.goTo(st.home)
return { ok = ok, why = why, pos = st.pos }
]==]

return {
    title = "protected blocks and home approach",
    needs = { "state", "nav" },
    run = function(sim, H)
        local cases = {
            { name = "chest ahead", op = "f", at = { x = 0, y = 0, z = -1 }, block = "minecraft:chest" },
            { name = "barrel above", op = "u", at = { x = 0, y = 1, z = 0 }, block = "minecraft:barrel" },
            { name = "turtle below", op = "d", at = { x = 0, y = -1, z = 0 }, block = "computercraft:turtle_normal" },
            { name = "shulker ahead", op = "f", at = { x = 0, y = 0, z = -1 }, block = "minecraft:red_shulker_box" },
            { name = "modem ahead", op = "f", at = { x = 0, y = 0, z = -1 }, block = "computercraft:wireless_modem_normal" },
        }
        for _, c in ipairs(cases) do
            sim.reset()
            local ctx = H.navSetup({ world = function(w) w:set(c.at.x, c.at.y, c.at.z, c.block) end })
            local r = ctx.drive({ c.op }, { keepGoing = true })
            H.check(r.status == "exit", "%s: driver did not finish: %s %s", c.name, r.status, tostring(r.err))
            local res = r.ret[1].results[1]
            H.check(res.ok == false and res.why == "protected", "%s: expected false,\"protected\", got %s,%s",
                c.name, tostring(res.ok), tostring(res.why))
            H.check(ctx.w:get(c.at.x, c.at.y, c.at.z) == c.block, "%s: block was dug", c.name)
            H.check(H.samePos(ctx.t.pos, { x = 0, y = 0, z = 0 }), "%s: turtle moved", c.name)
        end

        -- goTo(home) from below and to the side with the tunnel blocked by bedrock: the only
        -- fallback would be "climb first" (dig straight up into the base) -> must fail instead.
        sim.reset()
        local ctx = H.navSetup({})
        local r = ctx.drive({ "d", "d", "d", "f", "f" })
        H.check(r.status == "exit", "drive to (0,-3,-2) failed: %s %s", r.status, tostring(r.err))
        ctx.w:set(0, -3, -1, "minecraft:bedrock")
        ctx.t.fs:write("gohome.lua", GOHOME_SRC)
        local dug0 = #ctx.w.digLog
        local g = sim.boot(ctx.t, { "gohome" }, { maxTime = 600 })
        H.check(g.status == "exit", "gohome did not finish: %s %s", g.status, tostring(g.err))
        local res = g.ret[1]
        H.check(res.ok == false, "goTo(home) succeeded through a climb-first fallback (at %s) %s %s", H.fmtPos(ctx.t.pos), tostring(res.ok), tostring(res.why))
        H.check(#ctx.w.digLog == dug0, "goTo(home) dug %d blocks trying to get home", #ctx.w.digLog - dug0)
        H.check(H.samePos(ctx.t.pos, { x = 0, y = -3, z = -2 }), "turtle moved: %s", H.fmtPos(ctx.t.pos))

        -- the same blocked route to a non-home target may still use the fallback order
        sim.reset()
        ctx = H.navSetup({})
        r = ctx.drive({ "d", "d", "d", "f", "f" })
        ctx.w:set(0, -3, -1, "minecraft:bedrock")
        ctx.t.fs:write("gohome.lua", (GOHOME_SRC:gsub("nav%.goTo%(st%.home%)", "nav.goTo({x=0,y=-1,z=0})")))
        g = sim.boot(ctx.t, { "gohome" }, { maxTime = 600 })
        H.check(g.status == "exit" and g.ret[1].ok, "non-home goTo with fallback failed: %s %s",
            tostring(g.ret and g.ret[1] and g.ret[1].why), tostring(g.err))
        return "chest/barrel/shulker/turtle/modem never dug; goTo(home) fails instead of climbing first"
    end,
}
