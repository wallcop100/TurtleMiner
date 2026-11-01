-- Version: 1.0.0
-- Scenario 55 (MU-0): creating and joining a mining network.
--  A: `install --default --create base` on a fresh turtle: new network, 4 words shown
--  B: `install --default --join` with a typo: refused with "did you mean", nothing saved
--  C: `install --default --join LAVA, oak Ember-pick --name sim`: the shared test network
--  D: interactive join (typed answers): a typo, the suggestion, then the right words
--  E: `setup monitor --join ...` on a fresh computer (files from GitHub, HTTP stubbed)
--  F: server UI (keyboard only): NET -> PHRASE -> YES SHOW shows the words; TO DISK writes
--     the network to a floppy; `setup network --disk --wipe-disk` on a new computer joins
--     from it and wipes it
--  G: approve on the monitor: two computers ask to join; the one approved gets the network,
--     the other gets nothing and gives up after 2 minutes
local function readRepo(sim, path)
    local f = io.open(sim.REPO .. "/" .. path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

local function netOf(sim, c)
    local s = c.fs:read(".tm_network")
    return s and sim.textutils.unserialize(s) or nil
end

return {
    title = "create / join a mining network: flags, typos, setup, disk, approve",
    needs = { "tmcrypto", "tmwords", "tmjoin", "updater" },
    needsFile = "setup.lua",
    run = function(sim, H)
        local w = sim.world()
        local function install(id, args)
            local t = sim.turtle(w, { id = id, pos = { x = id * 3, y = 0, z = 0 }, network = false })
            local argv = { "install" }
            for _, a in ipairs(args) do argv[#argv + 1] = a end
            local r = sim.boot(t, argv, { maxTime = 120 })
            return t, r, table.concat(t.computer.output)
        end

        -- A: create ------------------------------------------------------------------
        local tA, rA, outA = install(1, { "--default", "--create", "base" })
        local nA = netOf(sim, tA.computer)
        H.check(rA.status == "exit", "A: install %s: %s", rA.status, tostring(rA.err))
        H.check(nA and nA.name == "base" and #nA.words == 4 and #nA.key == 64, "A: no network saved:\n%s", outA)
        local phrase = table.concat(nA.words, " ")
        H.check(outA:find(phrase, 1, true), "A: the 4 words were not shown:\n%s", outA)
        H.check(H.C.deriveKey("base", nA.words) == nA.key, "A: key does not match its words")
        local tA2 = install(2, { "--default", "--create", "base" })
        H.check(netOf(sim, tA2.computer).key ~= nA.key, "A: two creates made the same network")

        -- B: typo ----------------------------------------------------------------------
        local tB, rB, outB = install(3, { "--default", "--join", "lava", "oak", "embr", "pick" })
        H.check(not tB.fs:read(".tm_network"), "B: network saved from a typo'd phrase")
        H.check(outB:find("did you mean 'ember'", 1, true), "B: no suggestion:\n%s", outB)
        H.check(not outB:find("Settings:", 1, true), "B: install went on without a network")

        -- C: odd case / separators --------------------------------------------------------
        local tC, rC, outC = install(4, { "--default", "--join", "LAVA,", "oak", "Ember-pick", "--name", "sim" })
        local nC = netOf(sim, tC.computer)
        H.check(nC and nC.key == H.NET.key, "C: joined a different network:\n%s", outC)

        -- D: interactive with a typo -------------------------------------------------------
        local cD = sim.computer({ id = 5, network = false })
        H.installShared(cD)
        cD.inputs = { "2", "sim", "lava oak emberr pick", "lava oak ember pick" }
        local resD
        sim.boot(cD, function(G)
            local J = assert(G.loadfile("tmjoin.lua", nil, G))()
            resD = { J.ensure({}) }
        end, { maxTime = 30 })
        local outD = table.concat(cD.output)
        H.check(resD and resD[1] and resD[1].key == H.NET.key, "D: interactive join failed:\n%s", outD)
        H.check(outD:find("did you mean 'ember'", 1, true), "D: no suggestion for the typo:\n%s", outD)

        -- E: setup.lua over (stubbed) HTTP ---------------------------------------------------
        local cE = sim.computer({ id = 6, network = false })
        cE.fs:write("setup.lua", readRepo(sim, "setup.lua"))
        local fetched = 0
        cE.http = function(url)
            local path = url:match("vigilant%-pasteur%-g2krss/(.+)$")
            local body = path and readRepo(sim, path)
            if body then fetched = fetched + 1 end
            return body
        end
        local rE = sim.boot(cE, { "setup", "monitor", "--join", "lava", "oak", "ember", "pick", "--name", "sim" }, { maxTime = 60 })
        local nE = netOf(sim, cE)
        H.check(rE.status == "exit" and nE and nE.key == H.NET.key, "E: setup %s, network %s:\n%s", rE.status,
            tostring(nE and nE.name), cE.term._text())
        H.check(cE.fs:read("tmcrypto.lua") and cE.fs:read("tmjoin.lua") and cE.fs:read("tminer_server.lua"),
            "E: setup did not install the network modules")

        -- F: server UI: show phrase, copy to disk; join from disk ------------------------------
        local S = H.serverComputer({ id = 10, basic = true })
        sim.drivePeripheral(S.c, "left", "disk")
        sim.run({ maxTime = 3 })
        local K = S.c.env.keys
        local kb
        for _, u in ipairs(S.T.S.uis) do if u.side == nil then kb = u end end
        local function press(k) sim.key(S.c, k); sim.run({ maxTime = 0.1 }) end
        local function activate(label)
            for _ = 1, 60 do
                local b = kb.focus and kb.buttons[kb.focus]
                if b and b.key == label then press(K.enter); return end
                press(K.tab)
            end
            H.fail("no button %q:\n%s", label, S.c.term._text())
        end
        activate("NET")
        H.check(kb.view == "net", "F: NET opened %s", kb.view)
        activate("PHRASE")
        H.check(kb.view == "netconfirm" and not S.c.term._text():find("ember", 1, true),
            "F: phrase shown without confirmation")
        activate("YES SHOW")
        H.check(S.c.term._text():find("ember", 1, true) and S.c.term._text():find("pick", 1, true),
            "F: phrase not shown:\n%s", S.c.term._text())
        activate("HIDE")
        activate("TO DISK")
        local diskFile = S.c.fs:read("disk/tm_network")
        H.check(diskFile and S.c.term._text():find("copied", 1, true), "F: TO DISK failed:\n%s", S.c.term._text())
        local cF = sim.computer({ id = 11, network = false })
        H.installShared(cF)
        cF.fs:write("setup.lua", readRepo(sim, "setup.lua"))
        sim.drivePeripheral(cF, "top", "disk")
        cF.fs:write("disk/tm_network", diskFile)                  -- the floppy moved over
        local rF = sim.boot(cF, { "setup", "network", "--disk", "--wipe-disk" }, { maxTime = 30 })
        local nF = netOf(sim, cF)
        H.check(nF and nF.key == H.NET.key, "F: disk join failed (%s):\n%s", rF.status, cF.term._text())
        H.check(not cF.fs:read("disk/tm_network"), "F: disk not wiped")

        -- G: approve on the monitor -----------------------------------------------------------
        local function asker(id)
            local c = sim.computer({ id = id, label = "new" .. id, network = false })
            H.installShared(c)
            c.fs:write("setup.lua", readRepo(sim, "setup.lua"))
            sim.boot(c, { "setup", "network", "--approve" }, { background = true })
            return c
        end
        local g1, g2 = asker(30), asker(31)
        sim.run({ maxTime = 12 })
        local list = S.T.joinList()
        H.check(#list == 2, "G: %d join requests listed", #list)
        H.check(not netOf(sim, g1) and not netOf(sim, g2), "G: a device joined without approval")
        for _, e in ipairs(sim.net.log) do
            H.check(not (type(e.msg) == "table" and e.msg.kind == "join_ok"), "G: join_ok sent before approval")
        end
        if kb.view ~= "net" then activate("NET") end
        activate("OK #30")
        sim.run({ maxTime = 10 })
        local n1 = netOf(sim, g1)
        H.check(n1 and n1.key == H.NET.key, "G: approved device did not join:\n%s", g1.term._text())
        sim.run({ maxTime = 130 })
        H.check(not netOf(sim, g2), "G: unapproved device joined")
        H.check(g2.term._text():find("not approved", 1, true), "G: unapproved device did not give up:\n%s", g2.term._text())
        H.check(#S.T.joinList() == 0, "G: request still listed after 2 minutes")

        H.note(string.format("A created 'base' (%s); B typo refused with suggestion; C/D/E joined (E fetched %d files);"
            .. " F phrase after confirm, disk join + wipe; G approved #30, #31 got nothing", phrase, fetched))
    end,
}
