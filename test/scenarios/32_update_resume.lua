-- Version: 1.0.0
-- Scenario 32 (review #12): UPDATE while mining runs at the next home visit and the
-- turtle then carries on with what it was doing (never parks IDLE "update pending").
--  A: no update server answers: back to work after the home visit.
--  B: an update server offers a newer config.lua: installed, one reboot, back to work.
--  C: UPDATE while IDLE after RETURN_HOME: still IDLE afterwards.
local function updateServer(sim, H, id, files)
    local seq = 0
    local function send(to, kind, body)
        seq = seq + 1
        local m = { v = 1, kind = kind, from = id, to = to, boot = sim.BASE_EPOCH, seq = seq,
            ts = math.floor(sim.BASE_EPOCH + sim.now * 1000), hops = 0 }
        for k, v in pairs(body) do m[k] = v end
        sim.net.inject(id, nil, m, "TMINER")
    end
    local srv = { checks = 0, gets = 0 }
    sim.net.addNode(id, function(from, msg, protocol)
        if protocol ~= "TMINER" or type(msg) ~= "table" then return end
        if msg.kind == "update_check" then
            srv.checks = srv.checks + 1
            local list = {}
            for name, f in pairs(files) do list[#list + 1] = { name = name, version = f.version } end
            send(from, "update_manifest", { files = list })
        elseif msg.kind == "file_get" and msg.to == id and files[msg.name] then
            srv.gets = srv.gets + 1
            send(from, "file", { name = msg.name, version = files[msg.name].version, content = files[msg.name].content })
        end
    end)
    return srv
end

local function readRepo(sim, name)
    local f = assert(io.open(sim.REPO .. "/miner/" .. name, "rb"))
    local s = f:read("a")
    f:close()
    return s
end

local function phaseAfter(srv, id, phase, t0)
    for _, p in ipairs(srv.phases[id] or {}) do
        if p.time >= t0 and p.phase == phase then return p end
    end
end

local function idleSince(srv, id, t0)
    for _, p in ipairs(srv.phases[id] or {}) do
        if p.time >= t0 and p.phase == "IDLE" then return p end
    end
end

return {
    title = "UPDATE returns to the previous after-home state",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner", "updater" },
    run = function(sim, H)
        local big = { MAX_CORRIDORS = 4, MAIN_LENGTH = 16 }

        -- A: nothing to update ------------------------------------------------
        local ctx = H.minerSetup({ id = 40, settings = big })
        H.fillWhenAway(ctx, "minecraft:diamond", 0, 8)
        ctx.boot()
        H.runUntil(ctx, function() return ctx.phase() == "TO_WORK" and H.dist(ctx.t.pos, ctx.home) > 3 end, 600, "A: leaves home")
        local t0 = sim.now
        ctx.srv.cmd(40, "UPDATE")
        H.runUntil(ctx, function()
            local r = phaseAfter(ctx.srv, 40, "REFUELING", t0)
            return r and phaseAfter(ctx.srv, 40, "TO_WORK", r.time) and H.dist(ctx.t.pos, ctx.home) > 3
        end, 3600, "A: back to work after the home visit")
        local p = idleSince(ctx.srv, 40, t0)
        H.check(not p, "A: parked IDLE (%s)", tostring(p and p.reason))
        H.commonChecks(ctx)

        -- B: newer config.lua on the update server ---------------------------
        sim.reset()
        ctx = H.minerSetup({ id = 41, settings = big })
        local cfgSrc = readRepo(sim, "config.lua"):gsub("^%-%- Version: [%d%.]+", "-- Version: 99.0.0")
        local us = updateServer(sim, H, 200, { ["config.lua"] = { version = "99.0.0", content = cfgSrc } })
        H.fillWhenAway(ctx, "minecraft:diamond", 0, 8)
        ctx.boot()
        H.runUntil(ctx, function() return ctx.phase() == "TO_WORK" and H.dist(ctx.t.pos, ctx.home) > 3 end, 600, "B: leaves home")
        local boots = ctx.t.computer.bootN
        t0 = sim.now
        ctx.srv.cmd(41, "UPDATE")
        H.runUntil(ctx, function() return ctx.t.computer.bootN > boots end, 3600, "B: reboot after the update")
        local head = (ctx.t.fs:read("config.lua") or ""):match("^[^\n]*")
        H.check(head == "-- Version: 99.0.0", "B: config.lua not updated (%s)", tostring(head))
        local tb = sim.now
        H.runUntil(ctx, function()
            return phaseAfter(ctx.srv, 41, "TO_WORK", tb) and H.dist(ctx.t.pos, ctx.home) > 3
        end, 1200, "B: back to work after the update reboot")
        p = idleSince(ctx.srv, 41, t0)
        H.check(not p, "B: parked IDLE (%s)", tostring(p and p.reason))
        H.check(ctx.t.computer.bootN == boots + 1, "B: %d reboots", ctx.t.computer.bootN - boots)
        H.commonChecks(ctx)

        -- C: UPDATE while IDLE stays IDLE ------------------------------------
        sim.reset()
        ctx = H.minerSetup({ id = 42, settings = big })
        ctx.boot()
        H.runUntil(ctx, function() return H.dist(ctx.t.pos, ctx.home) > 8 end, 600, "C: out mining")
        ctx.srv.cmd(42, "RETURN_HOME")
        H.runUntil(ctx, function() return ctx.phase() == "IDLE" and ctx.atHome() end, 1200, "C: IDLE at home")
        ctx.srv.cmd(42, "UPDATE")
        sim.run({ maxTime = 120 })
        H.check(ctx.phase() == "IDLE", "C: phase %s after UPDATE while IDLE", tostring(ctx.phase()))
        H.commonChecks(ctx)
        return string.format("no update: back to work; update (%d check, %d file): one reboot, back to work; IDLE stays IDLE",
            us.checks, us.gets)
    end,
}
