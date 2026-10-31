-- Version: 1.0.0
-- Scenario 7: a cmd addressed to turtle 5 (broadcast on the air, to=5) is obeyed by 5
-- and ignored by 6; RETURN_HOME sent while 5 is in the middle of a vein brings it
-- home cleanly (unloaded, IDLE, position exact). REQUEST_STATUS answered (R8).
return {
    title = "addressed commands, RETURN_HOME mid-vein",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local srv = H.server()
        local w = sim.world()
        local c5 = H.minerSetup({ id = 5, w = w, srv = srv, home = { x = 0, y = 0, z = 0 } })
        -- turtle 6 has a long job so it is certainly still mining when 5 gets its command
        local c6 = H.minerSetup({ id = 6, w = w, srv = srv, home = { x = 200, y = 0, z = 0 },
            settings = { MAX_CORRIDORS = 20, MAIN_LENGTH = 32, BRANCH_LENGTH = 12 } })
        local TY = c5.worldTargetY
        -- iron vein right of corridor 0's main at f=2..3, r=1..3, two high
        local vein = {}
        for f = 2, 3 do
            for r = 1, 3 do
                for dy = 0, 1 do
                    local p = H.setGrid(c5, f, r, TY + dy, (r == 2) and "minecraft:deepslate_iron_ore" or "minecraft:iron_ore")
                    vein[#vein + 1] = p
                end
            end
        end
        local function veinDug()
            local n = 0
            for _, p in ipairs(vein) do if H.wasDug(c5, p.x, p.y, p.z) then n = n + 1 end end
            return n
        end
        c5.boot()
        c6.boot()
        H.runUntil(c5, function() return veinDug() >= 3 end, 3600, "turtle 5 starts mining the vein")
        H.check(veinDug() < #vein, "vein finished before the command could be sent")
        local digs6 = #H.dugGrid(c6)
        local id = srv.cmd(5, "RETURN_HOME")
        local tCmd = sim.now
        H.runUntil(c5, function()
            return c5.atHome() and c5.phase() == "IDLE"
        end, 1200, "turtle 5 home and IDLE after RETURN_HOME")
        local acks = srv.acks[id] or {}
        H.check(#acks >= 1 and acks[1].from == 5, "no ack from turtle 5 for RETURN_HOME")
        for _, a in ipairs(acks) do H.check(a.from == 5, "turtle %d acked a command addressed to 5", a.from) end
        H.check(H.invCount(c5.t, function(n) return n:find("raw_iron") end) == 0, "turtle 5 came home but did not unload the ore")
        -- turtle 6 kept working
        sim.run({ maxTime = 120 })
        H.check(#H.dugGrid(c6) > digs6 + 5, "turtle 6 stopped digging after a command meant for 5 (dug %d -> %d; phases %s; at %s)",
            digs6, #H.dugGrid(c6), srv.phaseList(6), H.fmtPos(c6.t.pos))
        for _, p in ipairs(srv.phases[6] or {}) do
            H.check(not (p.time > tCmd and p.phase == "IDLE"), "turtle 6 went IDLE after a command for turtle 5")
        end
        -- REQUEST_STATUS to 6 is answered promptly (and does not crash it)
        local n0 = #(srv.statuses[6] or {})
        local id2 = srv.cmd(6, "REQUEST_STATUS")
        sim.run({ maxTime = 3 })
        H.check(#(srv.statuses[6] or {}) > n0, "REQUEST_STATUS not answered within 3s")
        H.check(srv.acks[id2] and srv.acks[id2][1].ok ~= false, "REQUEST_STATUS not acked ok")
        -- RESUME 5 -> leaves IDLE
        srv.cmd(5, "RESUME")
        H.runUntil(c5, function() return c5.phase() ~= "IDLE" end, 60, "turtle 5 resumes after RESUME")
        H.commonChecks(c5)
        H.commonChecks(c6)
        return string.format("vein interrupted after %d/%d blocks; home in %.0fs", veinDug(), #vein, sim.now - tCmd)
    end,
}
