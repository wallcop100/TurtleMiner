-- Version: 1.0.0
-- Scenario 61 (MU-3 + MU-1 lists):
--  A: the file lists agree: setup.lua (stand-alone, own copy), tmmesh.SETS (the source of
--     truth), install.lua REQUIRED, the simulator's shared files.
--  B: "Check now" on the UPDATES screen of a wired-only PC without HTTP (#11), keyboard only:
--     it asks; #10 (HTTP + /files/) pulls from GitHub at once and answers; #11's screen shows
--     the result; the new file reaches #11 by mesh.
--  C: `updater --pull` on another computer: same, printed.
local function listOf(src, var)
    local body = src:match("local " .. var .. " = (%b{})")
    local out = {}
    if body then for n in body:gmatch('"([^"]+)"') do out[#out + 1] = n end end
    return out
end

local function set(list)
    local s = {}
    for _, x in ipairs(list) do s[x] = true end
    return s
end

local function same(a, b)
    for k in pairs(a) do if not b[k] then return false, k end end
    for k in pairs(b) do if not a[k] then return false, k end end
    return true
end

return {
    title = "Check now (keyboard) + updater --pull; file lists agree",
    needs = { "net", "tmmesh", "tmguard", "updater" },
    needsFile = "setup.lua",
    run = function(sim, H)
        -- A: lists ------------------------------------------------------------------------
        local Mesh = H.mesh()
        local setup = H.repo("setup.lua")
        local function locals(setName, prefix)
            local s = {}
            for _, n in ipairs(Mesh.SETS[setName]) do
                if n:sub(1, #prefix) == prefix then s[Mesh.localName(n)] = true end
            end
            return s
        end
        local MINER, NETM = listOf(setup, "MINER"), listOf(setup, "NETMODS")
        local SERVER, RELAY = listOf(setup, "SERVER"), listOf(setup, "RELAY")
        local ok, diff = same(set(MINER), locals("miner", "miner/"))
        H.check(ok, "setup MINER vs tmmesh miner set: %s", tostring(diff))
        local net = {}
        for _, n in ipairs(Mesh.NET_MODS) do if n:sub(1, 6) == "miner/" then net[Mesh.localName(n)] = true end end
        ok, diff = same(set(NETM), net)
        H.check(ok, "setup NETMODS vs tmmesh NET_MODS: %s", tostring(diff))
        local srv = set(SERVER)
        srv["tminer_startup.lua"], srv["github_pull.lua"] = true, true    -- installed by name in setup
        ok, diff = same(srv, locals("server", "servers/"))
        H.check(ok, "setup SERVER vs tmmesh server set: %s", tostring(diff))
        ok, diff = same(set(RELAY), locals("relay", "servers/"))
        H.check(ok, "setup RELAY vs tmmesh relay set: %s", tostring(diff))
        H.check(setup:find('shell.run("relay_startup")', 1, true) and setup:find('"servers/startup.lua", "tminer_startup.lua"', 1, true),
            "setup does not install the startups the mesh keeps current")
        local req = listOf(H.repo("miner/install.lua"), "REQUIRED")
        local ms = locals("miner", "miner/")
        for _, n in ipairs(req) do H.check(ms[n], "install REQUIRED %s not in the miner set", n) end
        for _, n in ipairs(H.SHARED_FILES) do H.check(net[n], "sim shared file %s not a NET module", n) end
        for _, n in ipairs(Mesh.NET_MODS) do
            for _, s in ipairs({ "miner", "server", "relay" }) do
                H.check(set(Mesh.SETS[s])[n], "%s missing from the %s set", n, s)
            end
        end
        H.check(set(Mesh.NET_MODS)["setup.lua"], "setup.lua is not kept current by mesh updates")

        -- B: Check now ----------------------------------------------------------------------
        local gh = H.github({})
        local wired = { side = "back", kind = "wired", net = "base" }
        local A = H.meshComputer({ id = 10, role = "server", http = gh.fn, modems = { wired, { side = "top", kind = "ender" } },
            settings = { pull_minutes = 0 } })
        local B = H.meshComputer({ id = 11, role = "server", modems = { wired }, basic = true })
        sim.run({ maxTime = 40 })
        local gets0 = gh.gets
        gh.over["servers/tm_views.lua"] = H.bump(H.repo("servers/tm_views.lua"), "9.6.0")
        local T = B.T()
        local ui
        for _, u in ipairs(T.S.uis) do if u.side == nil then ui = u end end
        H.check(ui, "#11 has no terminal UI")
        local K = B.c.env.keys
        local function press(k) sim.key(B.c, k); sim.run({ maxTime = 0.1 }) end
        local function activate(label)
            for _ = 1, 80 do
                local b = ui.focus and ui.buttons[ui.focus]
                if b and b.key == label then press(K.enter); return end
                press(K.tab)
            end
            H.fail("no button %q on #11:\n%s", label, B.c.term._text())
        end
        activate("UPD")
        H.check(ui.view == "updates", "UPDATES screen not open (view %s)", tostring(ui.view))
        local tAsk = sim.now
        activate("CHECK NOW")
        sim.run({ untilFn = function() return T.S.pullMsg and T.S.pullMsg:find("pulled", 1, true) ~= nil end, maxTime = 30 })
        H.check(gh.gets > gets0, "#10 did not pull from GitHub")
        H.check(T.S.pullMsg and T.S.pullMsg:find("#10 pulled: 1 new file", 1, true), "#11 shows: %s", tostring(T.S.pullMsg))
        local tPulled = sim.now - tAsk
        sim.run({ maxTime = 1 })
        H.check(B.c.term._text():find("#10 pulled: 1 new file", 1, true), "result not on #11's screen:\n%s", B.c.term._text())
        sim.run({ untilFn = function() return H.verOf(B.c, "tm_views.lua") == "9.6.0" and B.c.alive and B.T() and B.T().S end,
            maxTime = 600 })
        H.check(H.verOf(B.c, "tm_views.lua") == "9.6.0", "the pulled file did not reach #11")
        local tSpread = sim.now - tAsk

        -- C: updater --pull ----------------------------------------------------------------
        gh.over["servers/tm_ui.lua"] = H.bump(H.repo("servers/tm_ui.lua"), "9.6.0")
        local C = sim.computer({ id = 12, label = "cli", modems = { { side = "back", kind = "ender" } } })
        H.installShared(C)
        local r = sim.boot(C, { "updater", "--pull" }, { maxTime = 120 })
        local out = table.concat(C.output)
        H.check(r.status == "exit", "updater --pull: %s %s", r.status, tostring(r.err))
        H.check(out:find("#10 pulled from GitHub: 1 new file", 1, true), "updater --pull printed:\n%s", out)
        sim.run({ untilFn = function() return H.verOf(B.c, "tm_ui.lua") == "9.6.0" end, maxTime = 600 })
        H.check(H.verOf(B.c, "tm_ui.lua") == "9.6.0", "updater --pull result did not spread to #11")
        H.check(#B.c.term._violations == 0, "#11 wrote off screen")
        return string.format("lists agree (setup/tmmesh/install/sim); Check now on basic wired-only #11 (keyboard): pulled in %.1f s, on #11 after %.0f s; updater --pull ok",
            tPulled, tSpread)
    end,
}
