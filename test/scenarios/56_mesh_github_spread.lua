-- Version: 1.0.0
-- Scenario 56 (MU-1): a GitHub pull on one PC reaches every device over the mesh.
--   #10 server PC (wired + ender modem, /files/, HTTP), #11 wired-only server PC, #20 relay,
--   #30 pocket, turtles #1 #2 #3 mining (real miner, real startup). #3's modem is off during
--   the update (out of range) and comes back later.
--   GitHub has newer config.lua (turtles), tm_views.lua (computers), relay.lua (relays) and
--   tmwords.lua (everyone). Checks: every device ends with the new files, each rebooted once
--   for it, turtles installed only at home (never mid-trip), computers only once idle (a key
--   pressed on #11 holds it back for 30 s), #3 catches up after it is heard again.
local ENDER = "computercraft:wireless_modem_advanced"

return {
    title = "GitHub pull on one PC -> 2 PCs, relay, pocket, 3 turtles updated",
    needs = { "net", "miner", "tmmesh", "tmguard", "updater", "startup" },
    run = function(sim, H)
        local Mesh = H.mesh()
        local NEW = {
            ["miner/config.lua"] = H.bump(H.repo("miner/config.lua"), "9.1.0"),
            ["servers/tm_views.lua"] = H.bump(H.repo("servers/tm_views.lua"), "9.1.0"),
            ["servers/relay.lua"] = H.bump(H.repo("servers/relay.lua"), "9.1.0"),
            ["miner/tmwords.lua"] = H.bump(H.repo("miner/tmwords.lua"), "9.1.0"),
        }
        local gh = H.github({})
        local wired = { side = "back", kind = "wired", net = "base" }
        local A = H.meshComputer({ id = 10, role = "server", http = gh.fn,
            modems = { wired, { side = "top", kind = "ender" } }, settings = { pull_minutes = 60 } })
        local B = H.meshComputer({ id = 11, role = "server", modems = { wired } })
        local R = H.meshComputer({ id = 20, role = "relay", modems = { { side = "top", kind = "ender" } } })
        local P = H.meshComputer({ id = 30, role = "pocket", modems = { { side = "back", kind = "ender" } } })
        local w = sim.world()
        local turtles = {}
        for i = 1, 3 do
            local ctx = H.minerSetup({ id = i, w = w, home = { x = i * 20, y = 0, z = 0 },
                settings = { AUTO_UPDATE = true, MAX_CORRIDORS = 6, MAIN_LENGTH = 16 } })
            turtles[i] = ctx
        end
        -- passive status recorder only (no fleet heartbeats; the real PCs do that)
        for _, ctx in ipairs(turtles) do ctx.srv = turtles[1].srv end
        local applyAway = {}
        sim.observe(function(e)
            local c = e.computer
            if c.turtle and (e.kind == "fs_move" or e.kind == "fs_copy") and e.to == "config.lua" then
                local ctx = turtles[c.id]
                if ctx and not H.samePos(c.turtle.pos, ctx.home) then applyAway[#applyAway + 1] = c.id end
            end
        end)
        for _, ctx in ipairs(turtles) do sim.boot(ctx.t, { "startup" }, { background = true }) end
        turtles[3].t.equip.left = nil          -- #3 out of range
        sim.run({ maxTime = 60 })
        local devs = { A.c, B.c, R.c, P.c, turtles[1].t.computer, turtles[2].t.computer, turtles[3].t.computer }
        for _, c in ipairs(devs) do
            H.check(c.alive, "#%d not running before the update: %s %s", c.id, tostring(c.status), tostring(c.err))
        end
        local boots0 = {}
        for _, c in ipairs(devs) do boots0[c.id] = c.boots end
        H.check(A.T() and A.T().mesh, "#10 has no mesh engine: %s", tostring(A.T() and A.T().S.meshErr))

        -- GitHub gets newer files; #10 pulls (hourly backup -> here: Check now from its own UI code path)
        for k, v in pairs(NEW) do gh.over[k] = v end
        local t0 = sim.now
        A.T().checkNow()
        sim.key(B.c, B.c.env.keys.tab)           -- someone uses #11: it must wait 30 s idle
        local function has(c, path, ver) return H.verOf(c, path) == ver end
        local function done(c)
            if c.turtle then return has(c, "config.lua", "9.1.0") and has(c, "tmwords.lua", "9.1.0") end
            if c.id == 20 then return has(c, "relay.lua", "9.1.0") and has(c, "tmwords.lua", "9.1.0") end
            local ok = has(c, "tm_views.lua", "9.1.0") and has(c, "tmwords.lua", "9.1.0")
            if c.id == 10 then ok = ok and has(c, "files/config.lua", "9.1.0") and has(c, "files/relay.lua", "9.1.0") end
            return ok
        end
        local doneAt = {}
        local function track()
            for _, c in ipairs(devs) do if not doneAt[c.id] and done(c) then doneAt[c.id] = sim.now - t0 end end
        end
        sim.run({ untilFn = function()
            track()
            for i = 1, 6 do if not doneAt[devs[i].id] then return false end end
            return true
        end, maxTime = 1800 })
        local function logTail(c)
            local T = c.env and c.env.TMINER_SERVER
            if not T then return "" end
            local l = {}
            for i = math.max(1, #T.S.log - 12), #T.S.log do l[#l + 1] = T.S.log[i] end
            return table.concat(l, " | ") .. " meshErr=" .. tostring(T.S.meshErr) .. " err=" .. tostring(c.errors and c.errors[#c.errors])
        end
        for i = 1, 6 do
            local c = devs[i]
            if not doneAt[c.id] then H.note("#" .. c.id .. " log: " .. logTail(c) .. " / #10: " .. logTail(A.c)) end
            H.check(doneAt[c.id], "#%d not updated after 30 min (status %s %s; tm_views %s config %s relay %s)", c.id,
                tostring(c.status), tostring(c.err), tostring(H.verOf(c, "tm_views.lua")), tostring(H.verOf(c, "config.lua")),
                tostring(H.verOf(c, "relay.lua")))
        end
        H.check(not doneAt[3], "#3 updated while out of range")
        H.check(doneAt[11] >= 30, "#11 updated %.1f s after the pull although a key was pressed (needs 30 s idle)", doneAt[11])
        -- #3 comes back in range
        local tBack = sim.now
        turtles[3].t.equip.left = ENDER
        sim.queue(turtles[3].t.computer, sim.now, { "peripheral", "left", n = 2 })
        sim.run({ untilFn = function() track(); return doneAt[3] ~= nil end, maxTime = 1800 })
        H.check(doneAt[3], "#3 did not catch up after coming back (config %s)", tostring(H.verOf(devs[7], "config.lua")))
        sim.run({ maxTime = 120 })
        H.check(#applyAway == 0, "turtle(s) installed away from home: %s", table.concat(applyAway, ","))
        for _, c in ipairs(devs) do
            H.check(c.alive, "#%d stopped: %s %s", c.id, tostring(c.status), tostring(c.err))
            local n = c.boots - boots0[c.id]
            H.check(n == 1, "#%d rebooted %d times for the update (want 1)", c.id, n)
            H.check(not c.fs:read(".tm_mesh/rollback"), "#%d rolled back", c.id)
        end
        for _, ctx in ipairs(turtles) do H.commonChecks(ctx) end
        local order = {}
        for _, c in ipairs(devs) do order[#order + 1] = string.format("#%d %.0fs", c.id, doneAt[c.id]) end
        local slowest = 0
        for i = 1, 6 do slowest = math.max(slowest, doneAt[devs[i].id]) end
        local n, by, bytes = H.meshTraffic(t0)
        return string.format("all in-range devices updated within %.0f s (%s); #3 %.0f s after it came back; "
            .. "1 reboot each; turtles at home only; mesh msgs %d (%d chunks, %d KB)",
            slowest, table.concat(order, ", "), doneAt[3] - (tBack - t0), n, by.file_chunk or 0, math.floor(bytes / 1024))
    end,
}
