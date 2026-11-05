-- Version: 1.0.0
-- Scenario 59 (MU-2): a release that crashes on boot is rolled back and blocked everywhere;
-- a newer fixed version clears it.
--   #10 server PC (wired + ender, /files/, HTTP), #11 wired-only PC, #30 pocket, #1 turtle
--   (mining). GitHub gets tm_views.lua 9.4.0 that crashes tminer_server on #11 only and
--   config.lua 9.4.0 that crashes the miner. #11 installs it, crashes, restores the .bak,
--   restarts the old version and signs a bad mark; #10 and the pocket, already running it,
--   roll back too; the turtle rolls back its own crash at home. The monitor log says
--   "update tm_views.lua 9.4.0 rolled back on #11: crash: ...". Then 9.4.1 (fixed) spreads and
--   clears the marks.
return {
    title = "crashing release rolls back everywhere; fixed version clears it",
    needs = { "net", "miner", "tmmesh", "tmguard", "updater", "startup" },
    run = function(sim, H)
        local gh = H.github({})
        local wired = { side = "back", kind = "wired", net = "base" }
        local A = H.meshComputer({ id = 10, role = "server", http = gh.fn, modems = { wired, { side = "top", kind = "ender" } } })
        local B = H.meshComputer({ id = 11, role = "server", modems = { wired } })
        local P = H.meshComputer({ id = 30, role = "pocket", modems = { { side = "back", kind = "ender" } } })
        local ctx = H.minerSetup({ id = 1, settings = { AUTO_UPDATE = true, MAX_CORRIDORS = 6, MAIN_LENGTH = 16 } })
        sim.boot(ctx.t, { "startup" }, { background = true })
        local tc = ctx.t.computer
        sim.run({ maxTime = 60 })
        local origViews = H.repo("servers/tm_views.lua")
        local origCfg = H.repo("miner/config.lua")
        local v0 = origViews:match("^%-%- Version: ([%d%.]+)")
        local c0 = origCfg:match("^%-%- Version: ([%d%.]+)")
        gh.over["servers/tm_views.lua"] = H.bump(origViews, "9.4.0", nil,
            'if os.getComputerID() == 11 then error("boom on 11", 0) end')
        gh.over["miner/config.lua"] = H.bump(origCfg, "9.4.0", nil, 'error("config boom", 0)')
        A.T().checkNow()
        local ran = {}
        local comps = { A.c, B.c, P.c }
        local function watch()
            for _, c in ipairs(comps) do if H.verOf(c, "tm_views.lua") == "9.4.0" then ran[c.id] = true end end
            if H.verOf(tc, "config.lua") == "9.4.0" then ran[1] = true end
            -- the turtle crashes in the same instant it boots the new config: see its own mark
            local ET = H.engineOf(tc)
            for _, m in ipairs(ET and ET.badList() or {}) do if m.by == 1 then ran[1] = true end end
        end
        local function allBack()
            watch()
            for _, c in ipairs(comps) do
                local E = H.engineOf(c)
                if not (E and c.alive and H.verOf(c, "tm_views.lua") == v0 and #E.badList() >= 1) then return false end
            end
            return ran[11] and ran[1] and H.verOf(tc, "config.lua") == c0
        end
        sim.run({ untilFn = allBack, maxTime = 2400 })
        local function state()
            local o = {}
            for _, c in ipairs(comps) do
                local E = H.engineOf(c)
                o[#o + 1] = string.format("#%d %s v%s marks %s", c.id, c.status, tostring(H.verOf(c, "tm_views.lua")),
                    tostring(E and #E.badList()))
            end
            local ET = H.engineOf(tc)
            local pend = {}
            for _, p in ipairs(ET and ET.pending() or {}) do pend[#pend + 1] = p.name .. ">" .. p.want .. (p.staged and "s" or "") end
            o[#o + 1] = "turtle config " .. tostring(H.verOf(tc, "config.lua")) .. " " .. tc.status .. " us " .. tostring(ET and ET.stateText())
                .. " pending " .. table.concat(pend, ",") .. " phase " .. tostring(ctx.phase()) .. " bad " .. (function() local r = {} for _, m in ipairs(ET and ET.badList() or {}) do r[#r + 1] = table.concat(m.ids, "+") .. " by " .. m.by end return table.concat(r, "; ") end)()
                .. " rb=" .. tostring(tc.fs:read(".tm_mesh/rollback")) .. " prob=" .. tostring(tc.fs:read(".tm_mesh/probation") ~= nil) .. " boots " .. tc.boots
            return table.concat(o, "; ")
        end
        H.check(allBack(), "not rolled back everywhere: %s (ran: %s %s %s %s)", state(), tostring(ran[10]), tostring(ran[11]),
            tostring(ran[30]), tostring(ran[1]))
        sim.run({ untilFn = function()
            return table.concat(A.T().S.log, "\n"):find("config.lua 9.4.0 rolled back on #1", 1, true) ~= nil
        end, maxTime = 120 })
        local logA = table.concat(A.T().S.log, "\n")
        H.check(logA:find("update tm_views.lua 9.4.0 rolled back on #11: crash: ", 1, true),
            "#10's log does not show the rollback:\n%s", logA:sub(-1500))
        H.check(logA:find("config.lua 9.4.0 rolled back on #1: crash: ", 1, true), "turtle rollback not shown:\n%s", logA:sub(-1500))
        -- blocked: nobody installs 9.4.0 again
        sim.run({ maxTime = 300 })
        for _, c in ipairs(comps) do
            H.check(H.verOf(c, "tm_views.lua") == v0 and c.alive, "#%d: %s after the mark", c.id, tostring(H.verOf(c, "tm_views.lua")))
        end
        H.check(H.verOf(tc, "config.lua") == c0, "turtle reinstalled the bad config.lua")
        -- the fix
        gh.over["servers/tm_views.lua"] = H.bump(origViews, "9.4.1")
        gh.over["miner/config.lua"] = H.bump(origCfg, "9.4.1")
        local t1 = sim.now
        A.T().checkNow()
        sim.run({ untilFn = function()
            for _, c in ipairs(comps) do
                local E = H.engineOf(c)
                if not (E and H.verOf(c, "tm_views.lua") == "9.4.1" and #E.badList() == 0) then return false end
            end
            return H.verOf(tc, "config.lua") == "9.4.1"
        end, maxTime = 2400 })
        H.check(H.verOf(tc, "config.lua") == "9.4.1", "turtle did not get the fix: %s", state())
        for _, c in ipairs(comps) do
            local E = H.engineOf(c)
            H.check(H.verOf(c, "tm_views.lua") == "9.4.1", "#%d did not get the fix: %s", c.id, state())
            H.check(#E.badList() == 0, "#%d still shows the bad mark", c.id)
        end
        sim.run({ maxTime = 60 })
        for _, c in ipairs({ A.c, B.c, P.c, tc }) do H.check(c.alive, "#%d stopped: %s", c.id, tostring(c.err)) end
        H.commonChecks(ctx)
        return string.format("9.4.0 crashed #11 + turtle -> rolled back; #10%s pocket%s rolled back by mark; fix 9.4.1 everywhere after %.0f s, marks cleared",
            ran[10] and " (was running it)" or "", ran[30] and " (was running it)" or " (blocked)", sim.now - t1)
    end,
}
