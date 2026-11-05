-- Version: 1.0.1
-- Scenario 46 (CM-5 mesh): every non-turtle node relays TMINER between ALL its modems.
--   S  : wired-only server (central_monitor) on wired network w1
--   R1 : relay PC, wired w1 + basic wireless (surface)
--   R2 : relay PC, wired w2 + basic wireless (bridges network w2 to the air)
--   S2 : wired-only server (central_monitor) on wired network w2
--   T  : basic-modem turtle in wireless reach of R1 and R2 only
-- Both wired-only servers hear the turtle and get acks for their commands (both ways); hop
-- distances count wired links like any other; every message is transmitted at most once per
-- node (dedupe: no loops, no storm).
local BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }

return {
    title = "wired + wireless mesh, wired-only servers",
    needs = { "net" },
    needsFile = "servers/relay.lua",
    run = function(sim, H)
        local f = assert(io.open(sim.REPO .. "/servers/relay.lua", "rb"))
        local relaySrc = f:read("a")
        f:close()
        local w = sim.world()
        local s1 = H.monitorComputer({ id = 100, modems = { { side = "back", kind = "wired", net = "w1" } } })
        local s2 = H.monitorComputer({ id = 101, modems = { { side = "back", kind = "wired", net = "w2" } } })
        local function relay(id, net, pos)
            local c = sim.computer({ id = id, pos = pos, modems = {
                { side = "left", kind = "wired", net = net }, { side = "top", kind = "basic" } } })
            c.fs:write("relay.lua", relaySrc)
            H.installShared(c)
            sim.boot(c, { "relay" }, { background = true })
            return c
        end
        local r1 = relay(201, "w1", { x = 0, y = 40, z = 0 })
        local r2 = relay(202, "w2", { x = 300, y = 40, z = 0 })   -- 300 blocks from R1: no direct air link
        -- the turtle is near R1 only; R2 (and with it network w2) is out of reach at first
        local t = sim.turtle(w, { id = 1, pos = { x = 20, y = 10, z = 0 }, equip = BASIC })
        H.netOnly(t)
        sim.run({ maxTime = 60 })
        local nowMs = function() return sim.BASE_EPOCH + sim.now * 1000 end
        H.check(s1.rec(1) and nowMs() - s1.rec(1).lastSeen < 15000, "wired-only S1 does not hear the turtle via R1")
        H.check(t.computer.net.hop() == 2, "turtle hop %s, want 2 (S1 0 -wired- R1 1 -air- T 2)", tostring(t.computer.net.hop()))
        H.check(s2.rec(1) == nil, "S2 heard the turtle with no air link to R2")
        -- R2 placed within air reach: network w2 joins the mesh (R1 and R2 also hear each other)
        r2.pos = { x = 40, y = 40, z = 0 }
        sim.run({ maxTime = 60 })
        local t0 = sim.now
        for _, s in ipairs({ s1, s2 }) do
            local r = s.rec(1)
            H.check(r and nowMs() - r.lastSeen < 15000, "server %d does not hear the turtle", s.c.id)
            local id = s.M.issueCmd(1, "REQUEST_STATUS")
            H.check(not s.M.S.pending[id].queued, "server %d queued a command for a turtle it hears", s.c.id)
            sim.run({ maxTime = 5, untilFn = function() return s.M.S.pending[id] == nil end })
            H.check(r.cmd.state == "ok", "server %d -> turtle: %s %s", s.c.id, tostring(r.cmd.state), tostring(r.cmd.err))
        end
        -- each server hears the other one (fleet from S2 crosses w2 -> air -> w1)
        H.check(s1.rec(101) == nil, "a server was taken for a turtle")
        -- no loops: every (message, node) pair transmitted at most once
        sim.run({ maxTime = 120 })
        local seen, dup, total, orig = {}, 0, 0, 0
        for _, e in ipairs(sim.net.log) do
            if e.time >= t0 and type(e.msg) == "table" and e.msg.v == 1 then
                total = total + 1
                if e.msg.from == e.from and (e.msg.hops or 0) == 0 then orig = orig + 1 end
                local k = e.from .. "|" .. tostring(e.msg.from) .. ":" .. tostring(e.msg.boot) .. ":" .. tostring(e.msg.seq)
                if seen[k] then dup = dup + 1 end
                seen[k] = true
            end
        end
        H.check(dup == 0, "%d repeated transmissions of the same message by the same node (loop)", dup)
        H.check(total <= orig * 5, "%d transmissions for %d originals (5 nodes): storm", total, orig)
        H.check(r1.alive and r2.alive, "a relay stopped")
        local rt = r1.term._text()
        H.check(rt:find("modem basic (1 wireless, 1 wired)", 1, true) and rt:find("server 1 hop", 1, true),
            "R1 screen:\n%s", rt)
        -- basic computer: no mouse/touch/colour; keyboard alone reaches a turtle's card
        local K = s1.c.env.keys
        local ui = s1.M.newUI(s1.c.term, nil)
        ui.color = false
        s1.M.render(ui)
        local guard = 0
        while ui.view == "list" and guard < 20 do
            s1.M.navKey(ui, K.down)
            if ui.buttons[ui.focus] and ui.buttons[ui.focus].y1 == 2 then s1.M.navKey(ui, K.enter) end
            guard = guard + 1
        end
        H.check(ui.view == "detail" and ui.sel == 1, "keyboard navigation did not open the turtle card (view %s)", ui.view)
        return string.format("keyboard nav ok; turtle hop 2 via wired+air; both wired-only servers command it; %d tx for %d originals in 120 s, 0 loops",
            total, orig)
    end,
}
