-- Version: 1.0.0
-- Scenario 51: after RETURN_HOME the turtle sits IDLE at home and must still obey
-- every other command (user report: "returned by command" seemed to freeze it).
return {
    title = "IDLE after RETURN_HOME still takes commands",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local m = H.minerSetup({ id = 70, settings = { MAX_CORRIDORS = 3 } })
        local srv, t = m.srv, m.t
        m.boot()
        H.runUntil(m, function() return m.phase() == "TO_WORK" and t.pos.y < m.home.y - 3 end, 3600, "working")
        srv.cmd(70, "RETURN_HOME")
        H.runUntil(m, function() return m.phase() == "IDLE" and m.atHome() end, 1800, "IDLE at home")
        local function acked(id)
            for _, a in ipairs(srv.acks[id] or {}) do if a.from == 70 then return a end end
        end
        local results = {}
        for _, c in ipairs({ { "REQUEST_STATUS" }, { "SET", { key = "TARGET_Y", value = m.cfg.TARGET_Y } },
                             { "PAUSE" }, { "RETURN_HOME" }, { "UPDATE" } }) do
            local id = srv.cmd(70, c[1], c[2])
            H.runUntil(m, function() return acked(id) ~= nil end, 120, "ack for " .. c[1] .. " while IDLE")
            results[#results + 1] = c[1] .. (acked(id).ok and "=ok" or "=nack")
        end
        srv.cmd(70, "RESUME")
        H.runUntil(m, function() return m.phase() == "TO_WORK" end, 600, "RESUME from IDLE goes back to work")
        srv.cmd(70, "RETURN_HOME")
        H.runUntil(m, function() return m.phase() == "IDLE" and m.atHome() end, 1800, "second RETURN_HOME")
        srv.cmd(70, "RESUME")
        H.runUntil(m, function() return m.phase() == "TO_WORK" end, 600, "second RESUME")
        return "IDLE acks: " .. table.concat(results, " ")
    end,
}
