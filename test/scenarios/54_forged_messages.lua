-- Version: 1.0.0
-- Scenario 54 (MU-0): forged, tampered, replayed and stale messages are rejected.
--  A (turtle, real net.lua): commands that are unsigned, signed with another key, tampered
--    after signing, replayed (same copy again; same signature under a new seq), 11 minutes
--    old or 11 minutes in the future: none applied, none acked. A good one: applied once.
--  B (server, real tminer_server): a catch-up log 20 minutes old is accepted (its events carry
--    signed timestamps); a status 11 minutes old is not.
--  C (updates): update servers that are unsigned or on another network offer config.lua
--    99.0.0: the turtle's updater installs nothing. The network's own update server: installed.
local function fakeUpdateServer(sim, H, id, files, net)
    local seq, srv = 0, { active = true, checks = 0 }
    local function send(to, kind, body)
        seq = seq + 1
        local m = { v = 1, kind = kind, from = id, to = to, boot = sim.BASE_EPOCH, seq = seq,
            ts = H.epochMs(), hops = 0 }
        for k, v in pairs(body) do m[k] = v end
        if net then H.sign(m, net) end
        sim.net.inject(id, nil, m, "TMINER")
    end
    sim.net.addNode(id, function(from, msg, protocol)
        if not srv.active or protocol ~= "TMINER" or type(msg) ~= "table" then return end
        if msg.kind == "update_check" then
            srv.checks = srv.checks + 1
            local list = {}
            for name, f in pairs(files) do list[#list + 1] = { name = name, version = f.version } end
            send(from, "update_manifest", { files = list })
        elseif msg.kind == "file_get" and files[msg.name] then
            send(from, "file", { name = msg.name, version = files[msg.name].version, content = files[msg.name].content })
        end
    end)
    return srv
end

return {
    title = "forged / tampered / replayed / stale messages rejected",
    needs = { "net", "tmcrypto", "updater" },
    run = function(sim, H)
        local netB = H.network("other", { "river", "torch", "birch", "creek" })
        local w = sim.world()
        local srv = H.server({ id = 100 })
        local t = sim.turtle(w, { id = 1, pos = { x = 0, y = 0, z = 0 } })
        local c = H.netTurtle(t, "T1")
        sim.run({ maxTime = 12 })
        local seq = 5000
        local function cmdMsg(id, cmd, extra)
            seq = seq + 1
            local m = { v = 1, kind = "cmd", from = 100, to = 1, boot = sim.BASE_EPOCH + 1, seq = seq,
                ts = H.epochMs(), hops = 0, hop = 0, ohop = 0, mk = "ender", id = id, cmd = cmd, params = {} }
            for k, v in pairs(extra or {}) do m[k] = v end
            return m
        end
        local function inject(m) sim.net.inject(100, nil, m, "TMINER"); sim.run({ maxTime = 2 }) end
        local function acked(id) return srv.acks[id] ~= nil end

        -- A: forged ----------------------------------------------------------------------
        local bad0 = c.net.stats.bad
        inject(cmdMsg("u1", "PAUSE"))                                     -- unsigned
        inject(H.sign(cmdMsg("f1", "PAUSE"), netB))                       -- other network's key
        local fake = H.sign(cmdMsg("f2", "PAUSE"), netB)
        fake.net = H.C.netTag(H.NET.key)                                  -- our tag, wrong key
        inject(fake)
        local tm = H.sign(cmdMsg("t1", "PAUSE"))
        tm.cmd = "RETURN_HOME"                                            -- tampered after signing
        inject(tm)
        local tm2 = H.sign(cmdMsg("t2", "PAUSE"))
        tm2.hops, tm2.hop, tm2.mk = 2, 1, "basic"                         -- relay fields: still fine
        inject(tm2)
        H.check(H.appliedCount(c, "PAUSE") == 1 and acked("t2"), "relayed copy (hops/hop/mk changed) rejected")
        inject(H.sign(cmdMsg("o1", "RESUME", { ts = H.epochMs() - 11 * 60000 })))   -- too old
        inject(H.sign(cmdMsg("o2", "RESUME", { ts = H.epochMs() + 11 * 60000 })))   -- future
        H.check(H.appliedCount(c, "RETURN_HOME") == 0 and H.appliedCount(c, "RESUME") == 0
            and H.appliedCount(c, "PAUSE") == 1, "forged command applied: %s", (function()
                local o = {} for _, a in ipairs(c.applied) do o[#o + 1] = a.cmd .. "(" .. tostring(a.id) .. ")" end
                return table.concat(o, " ") end)())
        for _, id in ipairs({ "u1", "f1", "f2", "t1", "o1", "o2" }) do
            H.check(not acked(id), "turtle acked forged command %s", id)
        end
        H.check(c.net.stats.bad - bad0 >= 6, "bad messages counted %d", c.net.stats.bad - bad0)

        -- Replay: the same copy again (dedupe), and its signature under a new seq.
        local good = H.sign(cmdMsg("r1", "REQUEST_STATUS"))
        inject(good)
        local acks1 = #(srv.acks["r1"] or {})
        H.check(H.appliedCount(c, "REQUEST_STATUS") == 1 and acks1 == 1, "good command: applied %d, acks %d",
            H.appliedCount(c, "REQUEST_STATUS"), acks1)
        local again = {}
        for k, v in pairs(good) do again[k] = v end
        inject(again)
        H.check(#(srv.acks["r1"] or {}) == 1, "replayed copy acked again")
        again = {}
        for k, v in pairs(good) do again[k] = v end
        again.seq = again.seq + 1000
        inject(again)
        H.check(H.appliedCount(c, "REQUEST_STATUS") == 1 and #(srv.acks["r1"] or {}) == 1,
            "replay under a new seq accepted")

        -- B: server side: old catch-up accepted, old status not ------------------------
        local S = H.serverComputer({ id = 10 })
        sim.run({ maxTime = 5 })
        local function fromTurtle(id, kind, body, tsAgo)
            seq = seq + 1
            local m = { v = 1, kind = kind, from = id, to = "server", boot = sim.BASE_EPOCH + 2, seq = seq,
                ts = H.epochMs() - tsAgo, hops = 0, ohop = 1, mk = "ender" }
            for k, v in pairs(body) do m[k] = v end
            sim.net.inject(id, nil, H.sign(m), "TMINER")
            sim.run({ maxTime = 1 })
        end
        fromTurtle(6, "status", { label = "Stale", phase = "MINING" }, 11 * 60000)
        H.check(S.rec(6) == nil, "server accepted an 11 min old status")
        local evTs = H.epochMs() - 20 * 60000
        fromTurtle(7, "catchup", { events = { { eid = "7:1:1", ts = evTs, last = evTs, n = 1, level = "info",
            text = "vein iron x4" } }, dropped = 0 }, 20 * 60000)
        H.check(S.logText():find("vein iron x4 (catch-up)", 1, true), "old catch-up rejected:\n%s", S.logText())
        H.check(S.T.S.bad >= 1, "server did not count the stale status")
        S.kill()

        -- C: forged update servers -------------------------------------------------------
        local cfgSrc = t.fs:read("config.lua")
        local newer = cfgSrc:gsub("^%-%- Version: [%d%.]+", "-- Version: 99.0.0")
        local files = { ["config.lua"] = { version = "99.0.0", content = newer } }
        local function runUpdater()
            local res
            c.jobs[#c.jobs + 1] = function(net, G)
                local U = assert(G.loadfile("updater.lua", nil, G))("updater")
                local ok, info = U.run({ timeout = 2, fileTimeout = 2 })
                res = { ok = ok, reason = info.reason, files = info.files, rejected = U.rejected }
            end
            H.runUntil({ t = t }, function() return res ~= nil end, 30, "updater run")
            return res
        end
        local unsigned = fakeUpdateServer(sim, H, 200, files, nil)
        local foreign = fakeUpdateServer(sim, H, 201, files, netB)
        local r1 = runUpdater()
        H.check(not r1.ok and t.fs:read("config.lua") == cfgSrc, "forged update installed (%s)", tostring(r1.reason))
        H.check(unsigned.checks > 0 and foreign.checks > 0 and r1.rejected >= 2,
            "forged servers not asked / not rejected (%d replies ignored)", r1.rejected or -1)
        -- A forged file answer to a genuine manifest: also refused.
        unsigned.active, foreign.active = false, false
        local mixSeq = 0
        sim.net.addNode(202, function(from, msg, protocol)
            if protocol ~= "TMINER" or type(msg) ~= "table" then return end
            mixSeq = mixSeq + 1
            local m = { v = 1, from = 202, to = from, boot = sim.BASE_EPOCH, seq = mixSeq, ts = H.epochMs(), hops = 0 }
            if msg.kind == "update_check" then
                m.kind, m.files = "update_manifest", { { name = "config.lua", version = "99.0.0" } }
                H.sign(m)                                   -- genuine manifest...
            elseif msg.kind == "file_get" then
                m.kind, m.name, m.version, m.content = "file", "config.lua", "99.0.0", newer
                H.sign(m)
                m.content = newer .. "\nprint('owned')\n"    -- ...file tampered on the way
            else return end
            sim.net.inject(202, nil, m, "TMINER")
        end)
        local r2 = runUpdater()
        H.check(not r2.ok and t.fs:read("config.lua") == cfgSrc, "tampered file installed (%s)", tostring(r2.reason))
        H.note(string.format("A: 6 forged cmds dropped (bad=%d), relayed copy ok, replays ignored; B: 20 min old catch-up"
            .. " logged, 11 min old status dropped; C: unsigned/foreign update servers ignored (%s), tampered file refused (%s)",
            c.net.stats.bad, r1.reason, r2.reason))
    end,
}
