-- Version: 1.0.1
-- Army scenario helpers (docs/ARMY_PLAN.md, "Contracts (batch 0)"). Sim only.
--   local A = require("army")(sim, H)
--   A.need()                      skip the scenario unless servers/tm_army.lua and miner/group.lua exist
--   st  = A.station{ x,y,z,f, shaftTo }    world + typed station coords + chest behind the spot
--   ld  = A.leader(st, {kind="ender"|"basic", pos})   server PC running tminer_server (+ tm_army.lua)
--   ui  = A.ui()                  fake monitor node: ui.send(kind, body)  (to = "server")
--   rec = A.newArmy(st, ld, ui, {name, ores, targetY, geom, settings})   army_new, returns the record
--   t   = A.addTurtle(st, rec.name, {id, equip, gps})   a turtle at the station spot, GROUP set
--   ts  = A.joinTurtles(st, ld, name, n, {equip=, gps=}) n turtles joined one after the other
--   c   = A.counters(st)          {collisions, frozenHits, redug, redigTries, digs}; A.assertClean(st)
--   A.watchShaft(st); A.waitStats(st)   truth-based idle time of turtles inside the shaft columns
--   A.tap(); A.kinds()            counts of every TMINER message kind sent so far
--   A.done(rec, y?)               number of finished branches (on level y)
--   A.held(rec, tid)              branch keys and segment keys held by a turtle
--   A.runUntil(st, cond, maxTime, what)    sim.run with a large event budget and a diagnostic
-- Assumptions about the (parallel) modules: a turtle with setting GROUP=<name> standing on the
-- station spot joins by itself at boot (group.join); army_new may carry geom={bl,sp,ml}.
return function(sim, H)
    local A = { counts = {}, list = {} }
    local REPO = sim.REPO
    local DIRS = H.DIRS

    local function exists(p) return H.fileExists(REPO .. "/" .. p) end

    function A.available()
        return exists("servers/tm_army.lua") and exists("miner/group.lua")
    end

    function A.need(extra)
        if not A.available() then H.skip("SKIP: army modules missing") end
        for _, f in ipairs(extra or {}) do
            if not exists(f) then H.skip("SKIP: " .. f .. " missing") end
        end
    end

    -- station -----------------------------------------------------------------------
    -- opts: x,y,z,f (station origin, default 100,8,100, facing 0), shaftTo (dig shaft 1 [and 2
    -- if shaft2] down to this Y beforehand), world (sim.world opts)
    function A.station(opts)
        opts = opts or {}
        local S = { x = opts.x or 100, y = opts.y or 8, z = opts.z or 100, f = opts.f or 0 }
        local w = sim.world(opts.world)
        local st = { S = S, w = w, turtles = {}, ids = 0 }
        local F, R = DIRS[S.f], DIRS[(S.f + 1) % 4]
        function st.toWorld(f, r, y)
            return { x = S.x + f * F.x + r * R.x, y = y or S.y, z = S.z + f * F.z + r * R.z }
        end
        function st.spot() return st.toWorld(0, 0, S.y) end
        function st.shaftCell(k, y) return st.toWorld(1, k - 1, y) end
        local function air(f, r, y) local p = st.toWorld(f, r, y); w:set(p.x, p.y, p.z, "air") end
        for _, fr in ipairs({ { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { -2, 0 } }) do air(fr[1], fr[2], S.y); air(fr[1], fr[2], S.y + 1) end
        local ch = st.toWorld(-1, 0, S.y)
        w:chest(ch.x, ch.y, ch.z, {}, { size = 54 })
        st.chest = ch
        if opts.shaftTo then
            for y = S.y - 1, opts.shaftTo, -1 do
                air(1, 0, y)
                if opts.shaft2 then air(1, 1, y) end
            end
        end
        return st
    end

    -- leader --------------------------------------------------------------------------
    -- opts: id (100), kind "ender"|"basic" (modem), pos (default beside the station, one above)
    function A.leader(st, opts)
        opts = opts or {}
        local p = opts.pos or st.toWorld(-2, 1, st.S.y + 1)
        local srv = H.serverComputer({ id = opts.id or 100, label = "leader", pos = p, noBoot = true,
            modems = { { side = "back", kind = opts.kind or "ender" } }, monitor = { side = "top", w = 39, h = 14 } })
        local f = io.open(REPO .. "/servers/tm_army.lua", "rb")
        if f then srv.c.fs:write("tm_army.lua", f:read("a")); f:close() end
        srv.boot()
        sim.run({ maxTime = 30 })   -- cluster election: only the leader takes army messages
        st.leader = srv
        return srv
    end

    -- a computer with a (basic or ender) modem running servers/relay.lua at a world position
    function A.relay(pos, kind, id)
        local c = sim.computer({ id = id or 200, pos = pos, modemKind = kind or "ender" })
        local f = assert(io.open(REPO .. "/servers/relay.lua", "rb"))
        c.fs:write("relay.lua", f:read("a")); f:close()
        H.installShared(c)
        sim.boot(c, { "relay" }, { background = true })
        return c
    end

    function A.ui(id)
        local srv = H.server({ id = id or 90, beacon = false })
        local ui = { srv = srv }
        function ui.send(kind, body) return srv.send("server", kind, body, true) end
        return ui
    end

    function A.record(st, name)
        local T = st.leader and st.leader.T
        return T and T.S and T.S.armies and T.S.armies[name]
    end

    function A.newArmy(st, ld, ui, o)
        o = o or {}
        local S = st.S
        ui.send("army_new", { name = o.name or "alpha", station = { x = S.x, y = S.y, z = S.z, f = S.f },
            ores = o.ores or { "lapis", "gold" }, targetY = o.targetY, geom = o.geom })
        sim.run({ maxTime = 5 })
        local rec = A.record(st, o.name or "alpha")
        H.check(rec, "army_new: leader has no record for '%s'", o.name or "alpha")
        for k, v in pairs(o.settings or {}) do ui.send("army_set", { name = rec.name, key = k, value = v }) end
        sim.run({ maxTime = 2 })
        st.army = rec.name
        return rec
    end

    -- turtles -------------------------------------------------------------------------
    A.BASIC = { left = "computercraft:wireless_modem_normal", right = "minecraft:diamond_pickaxe" }

    -- opts: id, equip, gps (default false), settings. Standing on the station spot, facing S.f.
    function A.addTurtle(st, name, opts)
        opts = opts or {}
        st.ids = st.ids + 1
        local id = opts.id or (10 + st.ids)
        local p = opts.pos or st.spot()
        local t = sim.turtle(st.w, { id = id, label = "A" .. id, pos = p, facing = st.S.f, fuel = opts.fuel or 20000,
            fuelLimit = 100000, gps = opts.gps or false, equip = opts.equip })
        t.computer.label = "A" .. id
        local cfg = { TARGET_Y = st.S.y - 30, BRANCH_LENGTH = 4, BRANCH_SPACING = 3, MAIN_LENGTH = 8, MAX_CORRIDORS = 2,
            VEIN_MAX = 16, FUEL_MARGIN = 20, FUEL_KEEP = 4, FUEL_TARGET = 2000, STATUS_INTERVAL = 10,
            AUTO_UPDATE = false, STUCK_TIMEOUT = 60, HELP_RETRY = 30, SNAPSHOT_EVERY = 100, GROUP = name }
        if not opts.gps then cfg.HOME_Y = st.S.y end
        for k, v in pairs(opts.settings or {}) do cfg[k] = v end
        H.writeSettings(t, cfg)
        sim.boot(t, { "miner" }, { background = true })
        st.turtles[#st.turtles + 1] = t
        return t
    end

    -- n turtles one after the other (each must leave the spot before the next is placed)
    function A.joinTurtles(st, ld, name, n, opts)
        opts = opts or {}
        local out = {}
        for _ = 1, n do
            local t = A.addTurtle(st, name, opts)
            out[#out + 1] = t
            local rec = A.record(st, name)
            local sp = st.spot()
            A.runUntil(st, function()
                return rec.members and rec.members[t.id] and not H.samePos(t.pos, sp)
            end, opts.joinTime or 300, "turtle " .. t.id .. " joining and leaving the spot")
        end
        return out
    end

    -- counters --------------------------------------------------------------------------
    function A.counters(st)
        local w = st.w
        local hits = 0
        for _, c in ipairs(w.collisions) do if c.frozen then hits = hits + 1 end end
        local digs = 0
        for _, t in ipairs(st.turtles) do digs = digs + t.digs end
        return { collisions = #w.collisions, frozenHits = hits, redug = #w:redug(), redigTries = #w.redigTries, digs = digs }
    end

    function A.assertClean(st, what)
        local c = A.counters(st)
        local first = st.w.collisions[1]
        H.check(c.collisions == 0, "%s: %d collisions, first t=%.1f turtle %d into %d at %d,%d,%d", what or "run", c.collisions,
            first and first.time or 0, first and first.by or 0, first and first.with or 0, first and first.x or 0,
            first and first.y or 0, first and first.z or 0)
        H.check(c.redug == 0, "%s: %d cells dug twice", what or "run", c.redug)
        return c
    end

    -- shaft wait stats from the truth: seconds a turtle stands still inside a shaft column
    function A.watchShaft(st)
        local ws = { total = 0, max = 0, runs = 0, cur = {}, last = {} }
        st.wait = ws
        local S = st.S
        local function inShaft(p)
            if p.y >= S.y then return false end
            for k = 1, 2 do
                local c = st.shaftCell(k, p.y)
                if c.x == p.x and c.z == p.z then return true end
            end
            return false
        end
        sim.every(2, function()
            for _, t in ipairs(st.turtles) do
                local prev = ws.last[t.id]
                if inShaft(t.pos) and prev and prev == t.moves and not t.computer.frozen then
                    ws.cur[t.id] = (ws.cur[t.id] or 0) + 2
                    ws.total = ws.total + 2
                    if ws.cur[t.id] > ws.max then ws.max = ws.cur[t.id] end
                else
                    if ws.cur[t.id] then ws.runs = ws.runs + 1 end
                    ws.cur[t.id] = nil
                end
                ws.last[t.id] = t.moves
            end
        end, 2)
        return ws
    end

    function A.waitStats(st) return st.wait end

    -- message kinds -------------------------------------------------------------------
    function A.tap()
        if A.tapped then return end
        A.tapped = true
        sim.net.tap(function(from, to, msg, proto)
            if proto == "TMINER" and type(msg) == "table" and msg.kind then
                A.counts[msg.kind] = (A.counts[msg.kind] or 0) + 1
                A.list[#A.list + 1] = { time = sim.now, from = from, to = to, msg = msg }
            end
        end)
    end
    function A.kinds() return A.counts end

    -- queries ---------------------------------------------------------------------------
    function A.done(rec, y)
        local n = 0
        for key, b in pairs(rec.branches or {}) do
            if b.state == "done" and (y == nil or tonumber(key:match("^(-?%d+):")) == y) then n = n + 1 end
        end
        return n
    end

    function A.held(rec, tid)
        local br, sg = {}, {}
        for key, b in pairs(rec.branches or {}) do if b.tid == tid and b.state == "claimed" then br[#br + 1] = key end end
        for key, s in pairs(rec.segs or {}) do if s.holders and s.holders[tid] then sg[#sg + 1] = key end end
        table.sort(br); table.sort(sg)
        return br, sg
    end

    function A.inShaft(st, t)
        local S = st.S
        if t.pos.y >= S.y - 1 then return false end
        for k = 1, 2 do
            local c = st.shaftCell(k, t.pos.y)
            if c.x == t.pos.x and c.z == t.pos.z then return true end
        end
        return false
    end

    function A.runUntil(st, cond, maxTime, what)
        local r = sim.run({ untilFn = cond, maxTime = maxTime or 3600, maxTicks = 20000000 })
        if r.status ~= "until" then
            local rec = st.army and A.record(st, st.army)
            local pos = {}
            for _, t in ipairs(st.turtles) do
                local r = st.leader and st.leader.rec and st.leader.rec(t.id)
                local ph = r and r.st and (tostring(r.st.phase) .. ":" .. tostring(r.st.reason or r.st.why or "")) or "?"
                pos[#pos + 1] = string.format("%d@%d,%d,%d%s[%s]", t.id, t.pos.x, t.pos.y, t.pos.z, t.computer.alive and "" or "!", ph)
            end
            H.fail("%s: %s (%s); done %s; %s", what or "condition not reached", r.status, r.why or "",
                rec and A.done(rec) or "?", table.concat(pos, " "))
        end
        return r
    end

    return A
end
