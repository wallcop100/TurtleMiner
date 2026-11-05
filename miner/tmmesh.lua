-- Version: 1.1.1
-- TurtleMiner mesh updates (docs/MESH_UPDATE_PLAN.md sections 2-3, docs/PROTOCOL.md "Mesh
-- updates"). One module for every device: turtles (net.lua), server PCs and pockets
-- (tminer_server), relays (relay.lua) and the updater CLI.
--   * role file sets (M.SETS, the single list of what each kind of device holds)
--   * a tiny version summary per set (`vs`), added to messages devices already send
--   * signed release notes {name, version, sha256, size, origin, ts}; any device that holds a
--     file serves it (`list_get` -> `files_list`, chunked `file_get` -> `file_chunk`)
--   * one transfer at a time, resumable 16 KB chunks, rate-limited serving
--   * staging in .tm_mesh/stage/, all-or-nothing apply through tmguard.lua (.bak kept)
--   * origins: GitHub pull (originate) and manual edits (scan: a file whose `-- Version:` is
--     higher than its release is signed and announced)
--   * signed bad marks: spread like releases; bad releases are skipped, devices running one
--     roll back, a newer version clears it
-- The device decides WHEN to apply (turtles at home between trips, computers when idle); this
-- module decides WHAT. Lua 5.2 compatible (no bit operators, no goto).

local M = {}

M.CHUNK = 16384
M.REQ_TIMEOUT_MS = 6000       -- no reply to a list/chunk request: retry
M.RETRIES = 3                 -- then give up on that peer for now
M.ASK_GAP_MS = 60000          -- the same peer summary is asked for at most this often
M.SOURCE_MS = 300000          -- a source heard within this may be fetched from
M.PEER_MS = 120000            -- a peer heard within this is alive
M.SCAN_MS = 600000            -- manual-edit check (and at boot)
M.FIRST_SCAN_MS = 2000
M.SCAN_STEP = 24000         -- bytes hashed per step (CC kills code that never yields)
M.PROBATION_MS = 300000       -- computers: 5 minutes after an update
M.HOME_PROBATION_MS = 600000  -- turtles: first trip, or 10 minutes at home
M.SERVE_BURST, M.SERVE_EVERY_MS, M.SERVE_QUEUE = 4, 500, 16
M.ORIGIN_HOLD_MS = 60000     -- the origin serves a minute before it installs (and restarts) itself
M.DIR = ".tm_mesh/"

-- ---------------------------------------------------------------------------
-- Role file sets (repo paths). setup.lua keeps its own copy (it runs stand-alone from GitHub);
-- test scenario 61 checks the lists agree.
-- ---------------------------------------------------------------------------
local NET = { "miner/tmcrypto.lua", "miner/tmwords.lua", "miner/tmjoin.lua", "miner/tmmesh.lua",
    "miner/tmguard.lua", "miner/updater.lua", "setup.lua" }
local function join(a, b)
    local r = {}
    for _, x in ipairs(a) do r[#r + 1] = x end
    for _, x in ipairs(b) do r[#r + 1] = x end
    return r
end
M.NET_MODS = NET
M.SETS = {
    miner = join({ "miner/config.lua", "miner/state.lua", "miner/nav.lua", "miner/inv.lua", "miner/mine.lua", "miner/group.lua",
        "miner/net.lua", "miner/gpsmobile.lua", "miner/miner.lua", "miner/install.lua", "miner/startup.lua" }, NET),
    server = join({ "servers/tminer_server.lua", "servers/tm_db.lua", "servers/tm_radio.lua",
        "servers/tm_cluster.lua", "servers/tm_ui.lua", "servers/tm_views.lua", "servers/tm_update.lua", "servers/tm_gps.lua", "servers/tm_gpssolve.lua", "servers/tm_army.lua", "servers/tm_army_ui.lua",
        "servers/central_monitor.lua", "servers/startup.lua", "servers/update_server/github_pull.lua" }, NET),
    relay = join({ "servers/relay.lua", "servers/relay_startup.lua" }, NET),
}
M.SET_ORDER = { "miner", "server", "relay" }
M.SHORT = { miner = "m", server = "s", relay = "r" }
local SET_OF_SHORT = { m = "miner", s = "server", r = "relay" }
local IN_SET = {}
for set, list in pairs(M.SETS) do
    IN_SET[set] = {}
    for _, n in ipairs(list) do IN_SET[set][n] = true end
end

-- Local file name of a repo path.
function M.localName(name)
    if name == "servers/startup.lua" then return "tminer_startup.lua" end
    return (name:match("([^/]+)$"))
end

-- What a device holds: role "turtle" | "server" | "pocket" | "relay"; files = folder with the
-- turtles' (and relays') copies on an update-role server ("files/").
function M.layout(role, files)
    local L = { paths = {}, sets = {}, names = {} }
    local function add(set, prefix)
        L.sets[set] = true
        for _, n in ipairs(M.SETS[set]) do
            local p = prefix .. M.localName(n)
            local list = L.paths[n]
            if not list then list = {}; L.paths[n] = list; L.names[#L.names + 1] = n end
            local dup = false
            for _, q in ipairs(list) do if q == p then dup = true end end
            if not dup then list[#list + 1] = p end
        end
    end
    if role == "turtle" then add("miner", "")
    elseif role == "relay" then add("relay", "")
    else
        add("server", "")
        if files then
            files = files:gsub("^/+", "")
            if files ~= "" and files:sub(-1) ~= "/" then files = files .. "/" end
            add("miner", files)
            add("relay", files)
            L.files = files
        end
    end
    table.sort(L.names)
    return L
end

-- ---------------------------------------------------------------------------
-- Versions
-- ---------------------------------------------------------------------------
function M.versionOf(text)
    if type(text) ~= "string" then return nil end
    local first = text:match("^([^\n]*)") or ""
    return first:match("^%s*%-%-%s*[Vv]ersion:%s*(%d+%.%d+%.%d+)")
end

local function parts(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

-- -1 / 0 / 1; unparsable counts as 0.0.0
function M.compare(a, b)
    local pa, pb = parts(a) or { 0, 0, 0 }, parts(b) or { 0, 0, 0 }
    for i = 1, 3 do
        if pa[i] < pb[i] then return -1 end
        if pa[i] > pb[i] then return 1 end
    end
    return 0
end
local function newer(a, b) return M.compare(a, b) > 0 end

function M.compiles(name, text)
    if type(text) ~= "string" or #text == 0 then return false, "empty" end
    local fn, err = load(text, "=" .. name, "t", {})
    if not fn then return false, tostring(err) end
    return true
end

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------
local function readAll(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end
M.readAll = readAll

local function firstLine(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readLine()
    f.close()
    return s
end

local function writeAtomic(path, text)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local tmp = path .. ".tmp"
    if fs.exists(tmp) then fs.delete(tmp) end
    local f = fs.open(tmp, "w")
    if not f then return false end
    f.write(text)
    f.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
end
M.writeAtomic = writeAtomic

local function ser(t) return textutils.serialize(t) end
local function unser(s)
    if type(s) ~= "string" then return nil end
    local ok, v = pcall(textutils.unserialize, s)
    if ok and type(v) == "table" then return v end
    return nil
end

local function copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = copy(v) end
    return c
end

local function loadMod(name)
    if require then
        local ok, m = pcall(require, name)
        if ok and type(m) == "table" then return m end
    end
    for _, p in ipairs({ name .. ".lua", "/" .. name .. ".lua" }) do
        if fs and fs.exists(p) then
            local fn = loadfile(p, nil, _ENV)
            local ok, m = pcall(fn or error)
            if ok and type(m) == "table" then return m end
        end
    end
    return nil
end
M.loadMod = loadMod

-- Kinds this module handles (the device routes them here when addressed to it).
M.KINDS = { list_get = true, files_list = true, file_get = true, file_chunk = true, bad = true }

local function idOf(name, version) return tostring(name) .. "@" .. tostring(version) end
local function splitId(id) return id:match("^(.*)@(%d+%.%d+%.%d+)$") end
M.idOf, M.splitId = idOf, splitId

local function shortName(name) return (tostring(name):gsub("^miner/", ""):gsub("^servers/update_server/", "")
    :gsub("^servers/", "")) end
M.shortName = shortName

-- ---------------------------------------------------------------------------
-- Engine
-- o: role, files, key (network key; nil = can't sign), crypto, send(kind, to, body),
--    myId, log(text), now(), announce(), servesServer() (answer list_get to "server"),
--    atHome() (turtle), dir, guard (tmguard module)
-- ---------------------------------------------------------------------------
function M.new(o)
    o = o or {}
    local E = { o = o }
    local L = M.layout(o.role, o.files)
    E.L = L
    local C = o.crypto or loadMod("tmcrypto")
    local G = o.guard or loadMod("tmguard")
    E.G = G
    local signer = (o.key and C) and C.signer({ name = "mesh", key = o.key }) or nil
    local now = o.now or function() return os.epoch("utc") end
    local log = o.log or function() end
    local myId = o.myId or os.getComputerID()
    local dir = o.dir or M.DIR
    local STATE = dir .. "state"
    local isTurtle = o.role == "turtle"

    local st          -- persisted
    local dirty = true
    local sum = nil
    local known = {}  -- "<set short><hash>" whose full list we have seen
    local peers = {}  -- id -> {vs, at}
    local askQ = {}   -- peers worth asking for their list
    local asked = {}  -- id -> {at, key}
    local sources = {} -- name -> {[peer] = at}
    local listNotes = {} -- "<set short><summary>" -> {name = sha} (what a list with that summary had)
    local failed = {}  -- name -> {[peer] = true}: gave up on that peer for that name
    local job = nil
    local partial = {} -- name -> {sha, off, parts}
    local serveQ, tokens, refillAt = {}, M.SERVE_BURST, now()
    local bootAt = now()
    local lastScan = nil
    local rollbackWanted = {}
    local outbox = {}  -- own bad marks to broadcast
    local homeSince = nil
    local holdUntil = 0
    local probation = nil
    E.stats = { listsSent = 0, listsServed = 0, chunksSent = 0, chunksServed = 0, got = 0 }

    local function save() writeAtomic(STATE, ser(st)) end
    local function changed() dirty = true; sum = nil end
    local function warnOnce(key, text)
        if st.warned[key] then return end
        st.warned[key] = true
        save()
        log(text)
    end

    local function noteMac(t)
        local c = {}
        for k, v in pairs(t) do if k ~= "sig" then c[k] = v end end
        return signer.mac(c)
    end
    local function signTable(t)
        t.sig = noteMac(t)
        return t
    end
    local function validNote(n)
        return type(n) == "table" and n.t == "rel" and type(n.name) == "string" and parts(n.version) ~= nil
            and type(n.sha256) == "string" and #n.sha256 == 64 and type(n.size) == "number"
            and type(n.sig) == "string" and signer ~= nil and noteMac(n) == n.sig
    end
    local function validMark(m)
        return type(m) == "table" and m.t == "bad" and type(m.ids) == "table" and type(m.sig) == "string"
            and signer ~= nil and noteMac(m) == m.sig
    end

    -- held: what we can serve and run (staged beats installed)
    local function held(name) return st.staged[name] or st.inst[name] end
    E.held = held
    function E.heldVersion(name) local h = held(name); return h and h.version or nil end
    function E.names() return L.names end
    function E.paths(name) return L.paths[name] end
    function E.holds(name) return L.paths[name] ~= nil end

    local function isBad(name, version) return st.bad[idOf(name, version)] ~= nil end
    local function blocked(n) local id = idOf(n.name, n.version); return st.bad[id] ~= nil or st.broken[id] ~= nil end

    -- Names we want: a newer good release is known than what we hold.
    local function wantList()
        local w = {}
        for _, name in ipairs(L.names) do
            local b, h = st.best[name], held(name)
            if b and not blocked(b) and (not h or newer(b.version, h.version)) then w[#w + 1] = name end
        end
        return w
    end
    E.want = wantList

    local stableSum = nil
    function E.summary()
        if not E.scanned then return nil end
        if sum then return sum end
        -- Mid-download: keep advertising the last complete state, so peers don't ask about
        -- every half-fetched state (one list request per device per release, not per file).
        if stableSum and #wantList() > 0 then return stableSum end
        sum = {}
        for _, set in ipairs(M.SET_ORDER) do
            if L.sets[set] then
                local list = {}
                for _, name in ipairs(M.SETS[set]) do
                    local h = held(name)
                    list[#list + 1] = name .. "@" .. (h and h.version or "-")
                end
                local hsh = C.sha256hex(table.concat(list, ";")):sub(1, 6)
                sum[M.SHORT[set]] = hsh
                known[M.SHORT[set] .. hsh] = true
            end
        end
        local ids = {}
        for id in pairs(st.bad) do ids[#ids + 1] = id end
        if #ids > 0 then
            table.sort(ids)
            sum.b = C.sha256hex(table.concat(ids, ";")):sub(1, 6)
            known["b" .. sum.b] = true
        end
        stableSum = sum
        return sum
    end

    local function differs(vs, unknownOnly)
        local my = E.summary()
        for set in pairs(L.sets) do
            local k = M.SHORT[set]
            local h = vs[k]
            if type(h) == "string" and h ~= my[k] and not (unknownOnly and known[k .. h]) then return true end
        end
        local hb = vs.b
        if type(hb) == "string" and hb ~= my.b and not (unknownOnly and known["b" .. hb]) then return true end
        return false
    end

    -- ------------------------------------------------------------------ state
    local function stagePath(name) return dir .. "stage/" .. name end

    local function dropStaged(name)
        st.staged[name] = nil
        local p = stagePath(name)
        if fs.exists(p) then fs.delete(p) end
    end

    local function superseded(id)
        local name, ver = splitId(id)
        local b = name and st.best[name]
        return b ~= nil and newer(b.version, ver) and not st.bad[idOf(b.name, b.version)]
    end

    -- A bad id: forget it as a candidate, drop it if staged, roll back if running it.
    local function applyBadId(id)
        local name, ver = splitId(id)
        if not name then return end
        if st.best[name] and st.best[name].version == ver then
            local h = st.inst[name]
            st.best[name] = (h and h.version ~= ver) and copy(h) or nil
        end
        if st.staged[name] and st.staged[name].version == ver then dropStaged(name) end
        if st.inst[name] and st.inst[name].version == ver then rollbackWanted[name] = ver end
    end

    local function addMark(mark, own)
        if not own and not validMark(mark) then return false end
        local new = false
        for _, id in ipairs(mark.ids) do
            local idName = type(id) == "string" and splitId(id)
            if idName and L.paths[idName] and not st.bad[id] and not superseded(id) then
                st.bad[id] = mark.sig
                new = true
                applyBadId(id)
            end
        end
        if not new then return false end
        st.marks[mark.sig] = copy(mark)
        local shown = {}
        for _, id in ipairs(mark.ids) do
            local n, v = splitId(tostring(id))
            shown[#shown + 1] = n and (shortName(n) .. " " .. v) or tostring(id)
        end
        log("update " .. table.concat(shown, ", ") .. " rolled back on #" .. tostring(mark.by) .. ": "
            .. tostring(mark.reason))
        save()
        changed()
        if o.onBad then pcall(o.onBad, mark) end
        return true
    end

    function E.markBad(ids, reason)
        if not signer then return nil end
        local m = signTable({ t = "bad", ids = copy(ids), reason = tostring(reason or "?"):sub(1, 120), by = myId, ts = now() })
        if addMark(m, true) then outbox[#outbox + 1] = m end
        return m
    end

    -- Bad marks shown on monitors: not superseded yet.
    function E.badList()
        local out, seen = {}, {}
        for id, sig in pairs(st.bad) do
            local m = st.marks[sig]
            if m and not seen[sig] then
                seen[sig] = true
                out[#out + 1] = m
            end
        end
        table.sort(out, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
        return out
    end

    local function gcBad()
        local any = false
        for id in pairs(st.bad) do
            if superseded(id) then st.bad[id] = nil; any = true end
        end
        if any then
            local used = {}
            for _, sig in pairs(st.bad) do used[sig] = true end
            for sig in pairs(st.marks) do if not used[sig] then st.marks[sig] = nil end end
            changed()
        end
        return any
    end

    -- Learn a (verified) release note heard from a peer.
    local function learn(n, peer)
        if not L.paths[n.name] then return end
        local id = idOf(n.name, n.version)
        if st.bad[id] or st.broken[id] then return end
        local b = st.best[n.name]
        if not b or newer(n.version, b.version) then
            st.best[n.name] = copy(n)
            b = st.best[n.name]
            gcBad()
            changed()
        elseif b.version == n.version and b.sha256 ~= n.sha256 then
            warnOnce("c|" .. id, shortName(n.name) .. " " .. n.version .. " from #" .. tostring(peer)
                .. " differs from the release here: ignored (bump -- Version: when editing)")
            return
        end
        if b.version == n.version and peer then
            sources[n.name] = sources[n.name] or {}
            sources[n.name][peer] = now()
        end
    end

    -- ------------------------------------------------------------------ scan
    local hashed = 0
    local function hashOf(path, version, size)
        local c = st.hc[path]
        if c and c.v == version and c.size == size then return c.sha end
        local content = readAll(path)
        if not content then return nil end
        hashed = hashed + #content
        local sha = C.sha256hex(content)
        st.hc[path] = { v = version, size = #content, sha = sha }
        return sha
    end

    local function originateNote(name, content, version, sha)
        return signTable({ t = "rel", name = name, version = version, sha256 = sha, size = #content,
            origin = myId, ts = now() })
    end

    -- One name: installed state from disk; sign what has no release yet; detect manual edits.
    local function scanName(name, originated)
        local best = nil
        local list = {}
        for _, p in ipairs(L.paths[name]) do
            local line = firstLine(p)
            if line ~= nil then
                local v = M.versionOf(line) or "0.0.0"
                local size = fs.getSize(p)
                list[#list + 1] = { path = p, v = v, size = size }
                if not best or newer(v, best.v) then best = list[#list] end
            end
        end
        if not best then
            if st.inst[name] then st.inst[name] = nil; changed() end
        else
            local sha = hashOf(best.path, best.v, best.size)
            local mixed = false
            for _, e in ipairs(list) do
                if e ~= best and hashOf(e.path, e.v, e.size) ~= sha then mixed = true end
            end
            local inote = st.inst[name]
            if not (inote and inote.version == best.v and inote.sha256 == sha) then
                local cand = nil
                for _, n in ipairs({ st.staged[name], st.best[name] }) do
                    if n and n.version == best.v and n.sha256 == sha then cand = n end
                end
                local b = st.best[name]
                if cand then
                    st.inst[name] = copy(cand)
                elseif inote and inote.version == best.v then
                    warnOnce("e|" .. name .. "@" .. best.v .. "|" .. sha, shortName(name) .. " " .. best.v
                        .. " was changed without a version bump: not released (bump -- Version:)")
                    st.inst[name] = { t = "rel", name = name, version = best.v, sha256 = sha, size = best.size }  -- kept, not served
                elseif b and b.version == best.v and b.sha256 ~= sha then
                    warnOnce("c|" .. idOf(name, best.v) .. "|" .. sha, shortName(name) .. " " .. best.v
                        .. " here differs from the release: ignored (bump -- Version: when editing)")
                    st.inst[name] = { t = "rel", name = name, version = best.v, sha256 = sha, size = best.size }  -- kept, not served
                elseif isBad(name, best.v) then
                    st.inst[name] = { t = "rel", name = name, version = best.v, sha256 = sha, size = best.size }
                    rollbackWanted[name] = best.v
                elseif signer then
                    local content = readAll(best.path)
                    local okc, err = M.compiles(name, content)
                    if okc then
                        local n = originateNote(name, content, best.v, sha)
                        st.inst[name] = n
                        if not b or newer(best.v, b.version) then
                            st.best[name] = copy(n)
                            if b then originated[#originated + 1] = shortName(name) .. " " .. best.v end
                        end
                    else
                        warnOnce("l|" .. idOf(name, best.v), shortName(name) .. " " .. best.v
                            .. " does not compile, not released: " .. tostring(err):sub(1, 80))
                        st.inst[name] = { t = "rel", name = name, version = best.v, sha256 = sha, size = best.size }  -- kept, not served
                    end
                end
                changed()
            end
            -- A copy elsewhere on this device is out of date: stage the newest for it.
            local i = st.inst[name]
            if mixed and i and not st.staged[name] and i.sha256 == sha then
                local content = readAll(best.path)
                if content and writeAtomic(stagePath(name), content) then st.staged[name] = copy(i); changed() end
            end
        end
        -- staged but already installed: nothing to do
        local s, i = st.staged[name], st.inst[name]
        if s and i and not newer(s.version, i.version) and not mixed then dropStaged(name); changed() end
            end

    -- Incremental (hashing is slow in CC): scanStep(budget bytes) -> true when a full pass is
    -- done. The first full pass must finish before the device advertises or applies anything.
    local scanAt = nil
    local scanOrig = nil
    function E.scanStep(budget)
        if not scanAt then scanAt, scanOrig = 1, {} end
        hashed = 0
        while scanAt <= #L.names do
            scanName(L.names[scanAt], scanOrig)
            scanAt = scanAt + 1
            if hashed >= (budget or math.huge) then return false end
        end
        scanAt = nil
        lastScan = now()
        E.scanned = true
        gcBad()
        local originated = scanOrig
        if #originated > 0 then
            log("released (edited here): " .. table.concat(originated, ", "))
            if o.announce then pcall(o.announce) end
        end
        save()
        changed()
        return true, #originated
    end
    function E.scanning() return scanAt ~= nil end

    -- A full pass now; yieldFn() (e.g. sleep(0)) between steps keeps CC's watchdog happy.
    function E.scan(yieldFn)
        scanAt = nil
        while true do
            local done, n = E.scanStep(yieldFn and M.SCAN_STEP or nil)
            if done then return n end
            if yieldFn then yieldFn() end
        end
    end

    function E.ensureScan(yieldFn) if not E.scanned then E.scan(yieldFn) end end

    -- New content from GitHub (or any origin): sign, stage. Returns ok, why.
    function E.originate(name, content)
        if not E.scanned then return false, "not scanned yet" end
        if not L.paths[name] then return false, "not held here" end
        if not signer then return false, "no network" end
        local v = M.versionOf(content)
        if not v then return false, "no version line" end
        local okc, err = M.compiles(name, content)
        if not okc then return false, "does not compile: " .. tostring(err) end
        local id = idOf(name, v)
        if st.bad[id] then return false, "marked bad" end
        local h = held(name)
        local sha = C.sha256hex(content)
        if h and not newer(v, h.version) then
            if h.version == v and h.sha256 ~= sha then
                warnOnce("c|" .. id .. "|" .. sha, shortName(name) .. " " .. v .. " from GitHub differs from the release here: ignored")
            end
            return false, "not newer"
        end
        local n = originateNote(name, content, v, sha)
        if not writeAtomic(stagePath(name), content) then return false, "write failed" end
        st.staged[name] = n
        holdUntil = now() + M.ORIGIN_HOLD_MS
        local b = st.best[name]
        if not b or newer(v, b.version) then st.best[name] = copy(n) end
        gcBad()
        changed()
        save()
        return true
    end
    function E.announce() if o.announce then pcall(o.announce) end end

    -- ------------------------------------------------------------------ transfers
    local function send(kind, to, body)
        if o.send then return o.send(kind, to, body) end
    end

    local function listReply(to)
        local notes = {}
        for _, name in ipairs(L.names) do
            local h = held(name)
            if h and h.sig and not blocked(h) then notes[#notes + 1] = copy(h) end
        end
        local marks = {}
        for _, m in pairs(st.marks) do marks[#marks + 1] = copy(m) end
        send("files_list", to, { notes = notes, marks = marks, vs = copy(E.summary()) })
        E.stats.listsServed = E.stats.listsServed + 1
    end

    local cache = nil   -- {name, sha, content}
    local function contentFor(name, sha)
        if cache and cache.name == name and cache.sha == sha then return cache.content end
        local s = st.staged[name]
        local text = nil
        if s and s.sha256 == sha then
            text = readAll(stagePath(name))
        else
            local i = st.inst[name]
            if i and i.sha256 == sha then
                for _, p in ipairs(L.paths[name] or {}) do
                    local c = readAll(p)
                    if c and #c == i.size and C.sha256hex(c) == sha then text = c; break end
                end
            end
        end
        if text and #text > 0 and C.sha256hex(text) == sha then
            cache = { name = name, sha = sha, content = text }
            return text
        end
        return nil
    end

    local function serveChunk(msg)
        local name, sha, off = msg.name, msg.sha, tonumber(msg.off) or 0
        local text = type(name) == "string" and type(sha) == "string" and contentFor(name, sha) or nil
        if not text then
            send("file_chunk", msg.from, { name = name, sha = sha, off = off, err = "not here" })
            return
        end
        local h = held(name)
        if h and h.sha256 == sha and blocked(h) then
            send("file_chunk", msg.from, { name = name, sha = sha, off = off, err = "blocked" })
            return
        end
        send("file_chunk", msg.from, { name = name, sha = sha, off = off, total = #text,
            data = text:sub(off + 1, off + M.CHUNK) })
        E.stats.chunksServed = E.stats.chunksServed + 1
    end

    local function refill(t)
        local n = math.floor((t - refillAt) / M.SERVE_EVERY_MS)
        if n > 0 then
            tokens = math.min(M.SERVE_BURST, tokens + n)
            refillAt = refillAt + n * M.SERVE_EVERY_MS
        end
        if tokens >= M.SERVE_BURST then refillAt = t end
    end

    local function serveNext(t)
        refill(t)
        while #serveQ > 0 and tokens >= 1 do
            tokens = tokens - 1
            local m = table.remove(serveQ, 1)
            if m.kind == "list_get" then listReply(m.from) else serveChunk(m) end
        end
    end

    local function enqueueServe(msg)
        for i, q in ipairs(serveQ) do
            if q.from == msg.from and q.kind == msg.kind then serveQ[i] = msg; return end
        end
        if #serveQ >= M.SERVE_QUEUE then return end
        serveQ[#serveQ + 1] = msg
        serveNext(now())
    end

    local function requestChunk()
        send("file_get", job.peer, { name = job.name, sha = job.note.sha256, off = job.off })
        job.deadline = now() + M.REQ_TIMEOUT_MS
        E.stats.chunksSent = E.stats.chunksSent + 1
    end

    local function vsKey(vs)
        local out = {}
        for _, k in ipairs({ "m", "s", "r", "b" }) do out[#out + 1] = tostring(vs and vs[k]) end
        return table.concat(out, ",")
    end

    local function askList(peer, t)
        local p = peers[peer]
        asked[peer] = { at = t, key = vsKey(p and p.vs) }
        askQ[peer] = nil
        job = { kind = "list", peer = peer, deadline = t + M.REQ_TIMEOUT_MS, tries = 0 }
        send("list_get", peer, {})
        E.stats.listsSent = E.stats.listsSent + 1
    end

    local function mayAsk(id, t)
        local a = asked[id]
        local p = peers[id]
        return not a or a.key ~= vsKey(p and p.vs) or t - a.at >= M.ASK_GAP_MS
    end

    local function startNext(t)
        if job then return end
        -- 1. a peer with a summary we know nothing about
        local bestId, bestAt = nil, -1
        for id in pairs(askQ) do
            local p = peers[id]
            if not p or t - p.at > M.PEER_MS or not differs(p.vs, true) then askQ[id] = nil
            elseif mayAsk(id, t) and p.at > bestAt then bestId, bestAt = id, p.at end
        end
        if bestId then askList(bestId, t); return end
        -- 2. fetch a wanted file from a live source
        local want = wantList()
        for _, name in ipairs(want) do
            local b = st.best[name]
            -- Sources: peers whose list had it, and peers advertising a summary whose list had it
            -- (devices that finished become sources). A random one spreads the load.
            local cands = {}
            for id, at in pairs(sources[name] or {}) do
                local p = peers[id]
                if id ~= myId and t - at <= M.SOURCE_MS and p and t - p.at <= M.PEER_MS then cands[#cands + 1] = id end
            end
            for id, p in pairs(peers) do
                if id ~= myId and t - p.at <= M.PEER_MS and not (sources[name] and sources[name][id]) then
                    for k, h in pairs(p.vs) do
                        local ln = type(h) == "string" and listNotes[k .. h]
                        if ln and ln[name] == b.sha256 and not (failed[name] and failed[name][id]) then
                            cands[#cands + 1] = id
                            break
                        end
                    end
                end
            end
            local src = #cands > 0 and cands[math.random(1, #cands)] or nil
            if src then
                local pt = partial[name]
                if not (pt and pt.sha == b.sha256) then pt = { sha = b.sha256, off = 0, parts = {} }; partial[name] = pt end
                job = { kind = "file", name = name, note = b, peer = src, off = pt.off, tries = 0 }
                requestChunk()
                return
            end
        end
        -- 3. wanted but nobody known to have it: ask any live peer that differs
        if #want > 0 then
            for id, p in pairs(peers) do
                if t - p.at <= M.PEER_MS and differs(p.vs, false) and mayAsk(id, t) and p.at > bestAt then
                    bestId, bestAt = id, p.at
                end
            end
            if bestId then askList(bestId, t) end
        end
    end

    local function finishFile(t)
        local name, n, peer = job.name, job.note, job.peer
        local pt = partial[name]
        local content = table.concat(pt.parts)
        partial[name] = nil
        local id = idOf(name, n.version)
        job = nil
        if #content ~= n.size or C.sha256hex(content) ~= n.sha256 then
            st.fails = st.fails or {}
            st.fails[id] = (st.fails[id] or 0) + 1
            if sources[name] then sources[name][peer] = nil end
            if st.fails[id] >= M.RETRIES then
                st.broken[id] = "hash mismatch"
                warnOnce("h|" .. id, shortName(name) .. " " .. n.version .. ": content does not match its release note, not installed")
                changed()
            end
            save()
            return
        end
        local okc, err = M.compiles(name, content)
        if not okc then
            st.broken[id] = "does not compile"
            warnOnce("l|" .. id, shortName(name) .. " " .. n.version .. " does not compile, not installed: " .. tostring(err):sub(1, 80))
            changed()
            save()
            return
        end
        if writeAtomic(stagePath(name), content) then
            failed[name] = nil
            st.staged[name] = copy(n)
            E.stats.got = E.stats.got + 1
            changed()
            save()
        end
    end

    local function onChunk(msg, t)
        if not (job and job.kind == "file" and msg.from == job.peer and msg.name == job.name
            and msg.sha == job.note.sha256 and tonumber(msg.off) == job.off) then return end
        if msg.err or type(msg.data) ~= "string" then
            if sources[job.name] then sources[job.name][job.peer] = nil end
            job = nil
            return
        end
        local pt = partial[job.name]
        pt.parts[#pt.parts + 1] = msg.data
        pt.off = pt.off + #msg.data
        job.off = pt.off
        if pt.off >= job.note.size or #msg.data == 0 then
            finishFile(t)
        else
            job.tries = 0
            requestChunk()
        end
    end

    local function onList(msg, t)
        if job and job.kind == "list" and (job.peer == msg.from or job.peer == "server") then job = nil end
        if type(msg.notes) == "table" then
            for _, n in ipairs(msg.notes) do
                if validNote(n) then learn(n, msg.from) end
            end
        end
        if type(msg.marks) == "table" then
            for _, m in ipairs(msg.marks) do addMark(m, false) end
        end
        if type(msg.vs) == "table" then
            for k, h in pairs(msg.vs) do
                if type(h) == "string" then
                    known[k .. h] = true
                    local set = SET_OF_SHORT[k]
                    if set and type(msg.notes) == "table" then
                        local ln = {}
                        for _, n in ipairs(msg.notes) do
                            if type(n) == "table" and IN_SET[set][n.name] then ln[n.name] = n.sha256 end
                        end
                        listNotes[k .. h] = ln
                    end
                end
            end
            peers[msg.from] = { vs = msg.vs, at = t }
        end
        E.listsGot = (E.listsGot or 0) + 1
    end

    -- A message addressed to us (or "all" for `bad`) of one of M.KINDS. Returns true if used.
    function E.handle(msg)
        local k = msg.kind
        if not M.KINDS[k] or msg.from == myId then return false end
        if not E.scanned then return true end
        local t = now()
        if k == "list_get" then
            if msg.to == myId or (msg.to == "server" and o.servesServer and o.servesServer()) then enqueueServe(msg) end
        elseif k == "file_get" then
            if msg.to == myId and type(msg.sha) == "string" then enqueueServe(msg) end
        elseif k == "files_list" then
            if msg.to == myId then onList(msg, t) end
        elseif k == "file_chunk" then
            if msg.to == myId then onChunk(msg, t) end
        elseif k == "bad" then
            if type(msg.marks) == "table" then for _, m in ipairs(msg.marks) do addMark(m, false) end end
        end
        startNext(t)
        return true
    end

    -- Any message carrying a version summary.
    function E.heard(from, vs)
        if type(vs) ~= "table" or from == myId or type(from) ~= "number" or not E.scanned then return end
        local t = now()
        peers[from] = { vs = vs, at = t }
        if differs(vs, true) then askQ[from] = true end
        startNext(t)
    end

    -- Ask now (Check now on a turtle, the updater CLI): `to` = peer id or "server".
    function E.checkNow(to)
        local t = now()
        if job then return false end
        job = { kind = "list", peer = to or "server", deadline = t + M.REQ_TIMEOUT_MS, tries = 0 }
        send("list_get", to or "server", {})
        E.stats.listsSent = E.stats.listsSent + 1
        return true
    end

    -- ------------------------------------------------------------------ probation
    function E.probation() return probation end
    local function endProbation(why)
        if not probation then return end
        if G and G.passed then G.passed() elseif fs.exists(dir .. "probation") then fs.delete(dir .. "probation") end
        local ids = probation.ids or {}
        probation = nil
        log("update " .. table.concat(ids, ", "):gsub("miner/", ""):gsub("servers/", "") .. " passed probation (" .. why .. ")")
    end
    -- Turtles: a trip home completed.
    function E.tripDone() if probation then endProbation("trip done") end end

    -- ------------------------------------------------------------------ tick
    function E.tick()
        local t = now()
        if scanAt or (not lastScan and t - bootAt >= M.FIRST_SCAN_MS) or (lastScan and t - lastScan >= M.SCAN_MS) then
            E.scanStep(M.SCAN_STEP)
        end
        if #outbox > 0 and o.send then
            local marks = outbox
            outbox = {}
            send("bad", "all", { marks = marks })
        end
        if job and t > (job.deadline or 0) then
            job.tries = job.tries + 1
            if job.tries > M.RETRIES then
                if job.kind == "file" then
                    if sources[job.name] then sources[job.name][job.peer] = nil end
                    failed[job.name] = failed[job.name] or {}
                    failed[job.name][job.peer] = true
                end
                job = nil
            elseif job.kind == "file" then
                requestChunk()
                job.deadline = t + M.REQ_TIMEOUT_MS * (2 ^ job.tries)
            else
                if type(job.peer) == "number" then send("list_get", job.peer, {}) else job = nil end
                if job then job.deadline = t + M.REQ_TIMEOUT_MS * (2 ^ job.tries) end
            end
        end
        serveNext(t)
        startNext(t)
        if probation then
            if probation.limit and t - (probation.at or 0) >= probation.limit then endProbation("5 min ok")
            elseif isTurtle and o.atHome then
                local okH, home = pcall(o.atHome)
                if okH and home then
                    homeSince = homeSince or t
                    if t - homeSince >= M.HOME_PROBATION_MS then endProbation("10 min at home ok") end
                else
                    homeSince = nil
                end
            end
        end
    end

    -- ------------------------------------------------------------------ apply
    function E.ready()
        if not E.scanned then return nil end
        for name in pairs(rollbackWanted) do return "rollback" end
        if job and job.kind == "file" then return nil end
        if next(st.staged) == nil then return nil end
        if #wantList() > 0 then return nil end
        if now() < holdUntil then return nil end
        return "apply"
    end

    local function protectedSkip(path)
        -- A turtle's startup.lua is only replaced when it is ours (has a version line).
        if isTurtle and path == "startup.lua" and fs.exists(path) then
            local line = firstLine(path) or ""
            return M.versionOf(line) == nil and not (readAll(path) or ""):find("Written by install", 1, true)
        end
        return false
    end

    local NOT_RUNNING = { ["setup.lua"] = true, ["install.lua"] = true }
    local function isLive(path)
        if NOT_RUNNING[path] then return false end
        return not (L.files and path:sub(1, #L.files) == L.files)
    end

    local function rollbackNow()
        local items, names, ids = {}, {}, {}
        local reboot = false
        for name, ver in pairs(rollbackWanted) do
            local any = false
            for _, p in ipairs(L.paths[name] or {}) do
                local bak = p .. ".bak"
                local bv = M.versionOf(firstLine(bak) or "")
                if fs.exists(bak) and bv and newer(ver, bv) then
                    items[#items + 1] = { path = p }
                    any = true
                    if isLive(p) then reboot = true end
                end
            end
            if any then names[#names + 1] = name; ids[#ids + 1] = idOf(name, ver)
            else warnOnce("nb|" .. idOf(name, ver), shortName(name) .. " " .. ver .. " is marked bad but there is no older copy here: waiting for a newer version") end
        end
        rollbackWanted = {}
        if #items == 0 then return false, { files = {}, reason = "nothing to roll back" } end
        for _, it in ipairs(items) do
            if fs.exists(it.path) then fs.delete(it.path) end
            fs.copy(it.path .. ".bak", it.path)
        end
        for _, name in ipairs(names) do st.inst[name] = nil; st.hc = {} end
        if probation then
            if G and G.passed then G.passed() end
            probation = nil
        end
        save()
        log("rolled back " .. table.concat(ids, ", ") .. " (marked bad)")
        E.scanned, lastScan = false, nil
        return true, { files = names, reboot = reboot, rollback = true }
    end

    -- Install everything staged (all or nothing). Returns ok, {files, reboot}.
    function E.apply()
        if next(rollbackWanted) then return rollbackNow() end
        local items, names, ids = {}, {}, {}
        local live = false
        local contents = {}
        for name, n in pairs(st.staged) do
            local content = readAll(stagePath(name))
            if not content or #content ~= n.size or C.sha256hex(content) ~= n.sha256 then
                dropStaged(name)
                changed()
                save()
                return false, { files = {}, reason = shortName(name) .. ": staged copy damaged" }
            end
            contents[name] = content
            names[#names + 1] = name
            ids[#ids + 1] = idOf(name, n.version)
        end
        table.sort(names)
        table.sort(ids)
        -- Probation covers only files that run here: a crash can only blame those.
        local liveIds = {}
        for _, name in ipairs(names) do
            local nameLive = false
            for _, p in ipairs(L.paths[name]) do
                if not protectedSkip(p) and readAll(p) ~= contents[name] then
                    local lv = isLive(p)
                    items[#items + 1] = { path = p, stage = stagePath(name), live = lv }
                    if lv then live = true; nameLive = true end
                end
            end
            if nameLive then liveIds[#liveIds + 1] = idOf(name, st.staged[name].version) end
        end
        if #items > 0 then
            local j = { ids = liveIds, items = items, at = now(), kind = o.role, live = live,
                limit = (not isTurtle) and M.PROBATION_MS or nil }
            local okA, err = pcall(G.applyJournal, j)
            if not okA then
                log("apply failed: " .. tostring(err))
                return false, { files = {}, reason = "apply failed: " .. tostring(err) }
            end
            if live then probation = G.probation and G.probation() or nil end
        end
        for _, name in ipairs(names) do
            st.inst[name] = copy(st.staged[name])
            dropStaged(name)
            if package and package.loaded then package.loaded[(M.localName(name):gsub("%.lua$", ""))] = nil end
        end
        st.hc = {}
        changed()
        save()
        local shown = {}
        for _, id in ipairs(ids) do shown[#shown + 1] = shortName(id) end
        log("installed " .. table.concat(shown, ", ") .. (live and " (restart)" or ""))
        return true, { files = names, reboot = live }
    end

    -- Short text for monitors (`us`): nil when there is nothing going on.
    function E.stateText()
        if job and job.kind == "file" then
            local w = #wantList()
            return "get " .. shortName(job.name) .. (w > 1 and (" +" .. (w - 1)) or "")
        end
        local r = E.ready()
        if r == "rollback" then return "rollback" end
        if r then return "ready" end
        if probation then return "probation" end
        if #wantList() > 0 then return "want " .. #wantList() end
        return nil
    end
    function E.idle() return job == nil and next(askQ) == nil end
    function E.warnedKeys() return st.warned end
    function E.busy() return job ~= nil end
    function E.job() return job end

    -- What a check would install: {name, have, want}
    function E.pending()
        local out = {}
        for _, name in ipairs(wantList()) do
            local h = held(name)
            out[#out + 1] = { name = M.localName(name), repo = name, have = h and h.version or nil, want = st.best[name].version,
                missing = h == nil }
        end
        for name, n in pairs(st.staged) do
            local i = st.inst[name]
            out[#out + 1] = { name = M.localName(name), repo = name, have = i and i.version or nil, want = n.version,
                staged = true, missing = i == nil }
        end
        table.sort(out, function(a, b) return a.repo < b.repo end)
        return out
    end

    -- ------------------------------------------------------------------ init
    function E.init()
        st = unser(readAll(STATE)) or {}
        for _, k in ipairs({ "inst", "staged", "best", "bad", "marks", "broken", "warned", "hc" }) do
            if type(st[k]) ~= "table" then st[k] = {} end
        end
        -- staged files that vanished
        for name in pairs(st.staged) do
            if not fs.exists(stagePath(name)) or not L.paths[name] then st.staged[name] = nil end
        end
        -- an interrupted apply (power cut between swaps): finish it
        if G and G.pendingJournal and G.pendingJournal() then pcall(G.boot, true) end
        probation = G and G.probation and G.probation() or nil
        -- a crash rollback by the startup guard: mark the release bad (needs the key)
        local rb = G and G.readRollback and G.readRollback() or nil
        if rb and signer then
            st.hc = {}
            if type(rb.ids) == "table" then
                for _, id in ipairs(rb.ids) do
                    local name = splitId(tostring(id))
                    if name then st.inst[name] = nil end
                end
            end
            E.markBad(rb.ids or {}, rb.reason or "crashed")
            G.clearRollback()
            lastScan = nil
        end
        for name, n in pairs(st.inst) do
            if st.bad[idOf(name, n.version)] then rollbackWanted[name] = n.version end
        end
        changed()
        return E
    end

    return E
end

return M
