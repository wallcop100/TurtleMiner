-- Version: 1.0.1
-- Scenario 62 (MU-1): traffic bound with 20 devices.
--   3 server PCs (#10 wired + ender, /files/, HTTP; #11 wired + ender; #12 wired-only),
--   2 relays (#20, #21), 1 pocket (#30), 14 turtles (#101..#114, net.lua + mesh).
--   One GitHub pull with 4 newer files (one per set + a shared one). Counts every mesh
--   transmission (originals and relayed copies) until every device holds the new files, and
--   checks it is bounded: at most 3 list requests per device (retries included), at most twice the chunk
--   requests strictly needed, and quiet afterwards (no storm).
return {
    title = "20 devices: transmissions per update are bounded",
    needs = { "net", "tmmesh", "tmguard" },
    run = function(sim, H)
        local Mesh = H.mesh()
        local gh = H.github({})
        local wired = { side = "back", kind = "wired", net = "base" }
        local comps = {
            H.meshComputer({ id = 10, role = "server", http = gh.fn, modems = { wired, { side = "top", kind = "ender" } } }),
            H.meshComputer({ id = 11, role = "server", modems = { wired, { side = "top", kind = "ender" } } }),
            H.meshComputer({ id = 12, role = "monitor", modems = { wired } }),
            H.meshComputer({ id = 20, role = "relay", modems = { { side = "top", kind = "ender" } } }),
            H.meshComputer({ id = 21, role = "relay", modems = { { side = "top", kind = "ender" } } }),
            H.meshComputer({ id = 30, role = "pocket", modems = { { side = "back", kind = "ender" } } }),
        }
        local w = sim.world()
        local tcs = {}
        for i = 1, 14 do tcs[i] = H.netTurtle(sim.turtle(w, { id = 100 + i, pos = { x = i * 2, y = 0, z = 0 } })) end
        sim.run({ maxTime = 120 })
        -- quiet baseline
        local tb = sim.now
        sim.run({ maxTime = 150 })
        local baseN = H.meshTraffic(tb, { list_get = true, files_list = true, file_get = true, file_chunk = true })
        local NEW = {
            ["miner/config.lua"] = H.bump(H.repo("miner/config.lua"), "9.7.0"),
            ["servers/tm_views.lua"] = H.bump(H.repo("servers/tm_views.lua"), "9.7.0"),
            ["servers/relay.lua"] = H.bump(H.repo("servers/relay.lua"), "9.7.0"),
            ["miner/tmwords.lua"] = H.bump(H.repo("miner/tmwords.lua"), "9.7.0"),
        }
        for k, v in pairs(NEW) do gh.over[k] = v end
        -- chunk requests strictly needed: each device fetches each of its new files once
        local need = 0
        local function chunksFor(name) return math.ceil(#NEW[name] / Mesh.CHUNK) end
        local devices = {}
        for _, d in ipairs(comps) do devices[#devices + 1] = { c = d.c, role = d.role } end
        for _, c in ipairs(tcs) do devices[#devices + 1] = { c = c, role = "turtle" } end
        local function heldAll(d)
            local E = H.engineOf(d.c)
            if d.role == "relay" then
                return H.verOf(d.c, "relay.lua") == "9.7.0" and H.verOf(d.c, "tmwords.lua") == "9.7.0"
            end
            if not E then return false end
            for name in pairs(NEW) do
                if E.holds(name) and E.heldVersion(name) ~= "9.7.0" then return false end
            end
            return true
        end
        for _, d in ipairs(devices) do
            if d.c.id ~= 10 then
                local L = Mesh.layout(d.role == "monitor" and "server" or d.role, nil)
                for name in pairs(NEW) do if L.paths[name] then need = need + chunksFor(name) end end
            end
        end
        local t0 = sim.now
        comps[1].T().checkNow()
        local doneAt = nil
        sim.run({ untilFn = function()
            for _, d in ipairs(devices) do if not heldAll(d) then return false end end
            doneAt = sim.now
            return true
        end, maxTime = 1800 })
        local missing = {}
        for _, d in ipairs(devices) do if not heldAll(d) then missing[#missing + 1] = "#" .. d.c.id end end
        H.check(#missing == 0, "not updated after 30 min: %s", table.concat(missing, " "))
        local n, by, bytes = H.meshTraffic(t0)
        local lists = H.originals("list_get", t0)
        local _, nList = H.originals("list_get", t0)
        local _, nGet = H.originals("file_get", t0)
        local _, nChunk = H.originals("file_chunk", t0)
        local all = 0
        for _, e in ipairs(sim.net.log) do if e.time >= t0 then all = all + 1 end end
        local per = {}
        for id, k in pairs(lists) do per[#per + 1] = id .. ":" .. k end
        table.sort(per)
        H.check(nList <= 3 * #devices, "%d list requests for %d devices (%s)", nList, #devices, table.concat(per, " "))
        H.check(nGet <= 2 * need, "%d chunk requests, %d needed", nGet, need)
        -- quiet afterwards
        local tq = sim.now
        sim.run({ maxTime = 300 })
        local after = H.meshTraffic(tq, { list_get = true, files_list = true, file_get = true, file_chunk = true })
        H.check(after <= 2 * baseN + 2 * #devices, "still busy after the update: %d list/file messages in 5 min (baseline %d / 2.5 min)",
            after, baseN)
        for _, d in ipairs(devices) do H.check(d.c.alive, "#%d stopped: %s", d.c.id, tostring(d.c.err)) end
        local _ = lists
        return string.format("20 devices, 4 files: all had them %.0f s after the pull; mesh transmissions %d (incl. relayed copies; "
            .. "originals: %d list_get, %d file_get [%d needed], %d file_chunk; %d KB chunk data on air); all messages in that time %d; "
            .. "quiet afterwards (%d list/file msgs in 5 min)",
            doneAt - t0, n, nList, nGet, need, nChunk, math.floor(bytes / 1024), all, after)
    end,
}
