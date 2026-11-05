-- Version: 1.2.0
-- TurtleMiner relay (docs/COMMS.md rule 5). Run on any plain computer: opens every modem
-- (ender, basic wireless, wired) and relays TMINER traffic between them, with dedupe and a
-- hop limit. Nothing to configure:
--   * with an ender modem anywhere in the dimension: every turtle with any modem is in contact
--   * with a basic modem: covers 64 blocks around it (e.g. at the shaft bottom)
--   * with a wired modem too: bridges a wired network (e.g. a server in a base) to the air
-- Setting tminer.MODEM ("ender"/"basic") only overrides what it detects.
-- Mining network: relays only messages signed with this computer's network (.tm_network,
-- tmcrypto.lua next to it; `setup network` makes one). Everything else is dropped and counted.
-- The relayed copy is the original signed message; only hops/hop/via/mk change.
-- Mesh updates (tmmesh.lua): a beacon every 60 s carries this relay's version summary; it
-- fetches newer relay files from whoever has them, serves what it holds, installs at once
-- (a relay is always idle) and restarts once. Startup: relay_startup.lua (crash guard).
-- Usage: relay

local PROTO       = "TMINER"
local MAX_HOPS    = 4
local DEDUPE_MAX  = 512
local CONTACT_MS  = 30000
local HOP_LIMIT   = 8
local FAR         = 400       -- blocks: beyond any basic modem's range
local SERVER_KINDS = { fleet = true, cmd = true, home = true, update_manifest = true, file = true }

local myId = os.getComputerID()
local R = {
    kind = "none", wireless = 0, wired = 0, inferred = false,
    seen = {}, seenQ = {}, seenPos = 0,
    neigh = {}, heard = 0, relayed = 0, skipped = 0, last = "-",
}

local function now() return os.epoch("utc") end

local crypto, signer, netName
do  -- No mining network yet: ask on this computer's screen first.
    package.path = "/?.lua;/?;" .. package.path
    local okJ, J = pcall(require, "tmjoin")
    if okJ and J.bootPrompt then J.bootPrompt() end
end
do
    local ok, m = pcall(require, "tmcrypto")
    if not ok or type(m) ~= "table" then
        local fn = loadfile("tmcrypto.lua", nil, _ENV) or loadfile("/tmcrypto.lua", nil, _ENV)
        ok, m = pcall(fn or error)
    end
    if ok and type(m) == "table" then crypto = m end
    local n = crypto and crypto.loadNetwork()
    if n then signer, netName = crypto.signer(n), n.name end
end
R.bad = 0

local Mesh, mesh = nil, nil
local seq = math.random(1, 1000000)
local BOOT = now()
local BEACON_MS = 60000
local lastBeacon = 0

local function markSeen(key, sig)
    if R.seen[key] then return false end
    R.seenPos = R.seenPos % DEDUPE_MAX + 1
    local old = R.seenQ[R.seenPos]
    if old then R.seen[old] = nil end
    R.seenQ[R.seenPos] = key
    R.seen[key] = sig or true
    return true
end

local function updateKind()
    local o = settings and settings.get and settings.get("tminer.MODEM")
    if o == "ender" or o == "basic" or o == "wired" then R.kind = o
    elseif R.wireless > 0 then R.kind = R.inferred and "ender" or "basic"
    elseif R.wired > 0 then R.kind = "wired"
    else R.kind = "none" end
end

local function openModems()
    R.wireless, R.wired = 0, 0
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local okW, w = pcall(peripheral.call, name, "isWireless")
            if okW and w then R.wireless = R.wireless + 1 else R.wired = R.wired + 1 end
            pcall(rednet.open, name)
        end
    end
    updateKind()
end

-- 1 + the smallest fresh distance advertised by a neighbour (split horizon on `via`).
local function myHop()
    local t, best, via = now(), nil, nil
    for id, e in pairs(R.neigh) do
        if t - e.t > CONTACT_MS then R.neigh[id] = nil
        elseif not best or e.hop < best then best, via = e.hop, id end
    end
    if best and best + 1 < HOP_LIMIT then return best + 1, via end
    return nil
end

local function learn(sender, msg)
    local h = tonumber(msg.hop)
    if h == nil and msg.hop == nil and msg.ohop == nil and (tonumber(msg.hops) or 0) == 0 and SERVER_KINDS[msg.kind] then h = 0 end
    if h and h >= 0 and h < HOP_LIMIT and sender ~= myId and msg.via ~= myId then
        R.neigh[sender] = { hop = h, t = now() }
    end
end

-- Our own messages (beacons, mesh replies): signed, sent on every modem.
local function send(kind, to, body)
    if not signer then return end
    seq = seq + 1
    local msg = {}
    for k, v in pairs(body or {}) do msg[k] = v end
    msg.v, msg.kind, msg.from, msg.to = 1, kind, myId, to
    msg.boot, msg.seq, msg.ts, msg.hops = BOOT, seq, now(), 0
    local h, via = myHop()
    msg.hop, msg.ohop, msg.via, msg.mk = h, h, via, R.kind
    signer.sign(msg)
    markSeen(msg.from .. ":" .. msg.boot .. ":" .. msg.seq, msg.sig)
    pcall(rednet.broadcast, msg, PROTO)
    return msg
end

local function relayVersion()
    local v = mesh and mesh.heldVersion("servers/relay.lua")
    return v or "?"
end

local function beacon()
    if not mesh then return end
    lastBeacon = now()
    local body = { dev = "relay", ver = relayVersion(), label = os.getComputerLabel and os.getComputerLabel() or nil }
    local okS, vs = pcall(mesh.summary)
    if okS then body.vs = vs end
    local okU, us = pcall(mesh.stateText)
    if okU then body.us = us end
    send("beacon", "all", body)
end

local function startMesh()
    local ok, m = pcall(require, "tmmesh")
    if not ok or type(m) ~= "table" then
        local fn = loadfile("tmmesh.lua", nil, _ENV) or loadfile("/tmmesh.lua", nil, _ENV)
        ok, m = pcall(fn or error)
    end
    if not ok or type(m) ~= "table" or not signer or not crypto then return end
    Mesh = m
    local n = crypto.loadNetwork()
    local okE, e = pcall(function()
        return m.new({ role = "relay", key = n.key, crypto = crypto, myId = myId, send = send,
            log = function(text) R.last = "update: " .. tostring(text):sub(1, 60) end,
            announce = beacon }).init()
    end)
    if okE then mesh = e end
end

local function meshTick()
    if not mesh then return end
    pcall(mesh.tick)
    if now() - lastBeacon >= BEACON_MS then beacon() end
    local okR, r = pcall(mesh.ready)
    if okR and r then
        local okA, applied, info = pcall(mesh.apply)
        if okA and applied and info and info.reboot then
            R.last = "update installed, restarting"
            sleep(1)
            os.reboot()
        end
    end
end

local function handle(sender, msg)
    if type(msg) ~= "table" or msg.v ~= 1 or type(msg.kind) ~= "string" then return end
    if type(msg.from) ~= "number" or msg.from == myId then return end
    local hops = tonumber(msg.hops) or 0
    if hops > MAX_HOPS or not signer then return end
    local key = msg.from .. ":" .. tostring(msg.boot) .. ":" .. tostring(msg.seq)
    local known = R.seen[key]
    if known ~= nil then
        -- A copy of a message already checked: the same signature still tells us a distance.
        if known == msg.sig then learn(sender, msg) end
        return
    end
    local ok, why = signer.check(msg, now())
    if not ok then
        R.bad = R.bad + 1
        R.lastBad = tostring(why) .. " #" .. tostring(msg.from)
        return
    end
    learn(sender, msg)
    markSeen(key, msg.sig)
    R.heard = R.heard + 1
    R.last = msg.kind .. " #" .. msg.from
    if mesh then
        if type(msg.vs) == "table" then pcall(mesh.heard, msg.from, msg.vs) end
        if Mesh.KINDS[msg.kind] and (msg.to == myId or msg.to == "all") then pcall(mesh.handle, msg) end
    end
    -- Sent by an ender modem: every wireless modem heard it; only a wired side still needs it.
    if hops >= MAX_HOPS or (msg.mk == "ender" and R.wired == 0) then
        R.skipped = R.skipped + 1
        return
    end
    local c = {}
    for k, v in pairs(msg) do c[k] = v end
    c.hops = hops + 1
    c.hop, c.via = myHop()
    c.mk = R.kind
    if pcall(rednet.broadcast, c, PROTO) then R.relayed = R.relayed + 1 end
end

local function draw()
    if not term then return end
    pcall(function()
        local w = term.getSize()
        term.clear()
        local h, via = myHop()
        local lines = {
            "TMINER relay #" .. myId,
            "modem " .. R.kind .. " (" .. R.wireless .. " wireless, " .. R.wired .. " wired)",
            h and ("server " .. h .. " hop" .. (h == 1 and "" or "s") .. (via and (" via #" .. via) or ""))
                or "no server heard (30 s)",
            "heard " .. R.heard .. "  relayed " .. R.relayed,
            "last " .. R.last,
            signer and ("network '" .. netName .. "'  foreign/bad msgs: " .. R.bad)
                or "NO NETWORK: run `setup network`",
            "relay v" .. relayVersion() .. (mesh and mesh.stateText() and ("  update: " .. mesh.stateText()) or ""),
        }
        if R.wireless + R.wired == 0 then lines[2] = "NO MODEM: attach one" end
        for i, l in ipairs(lines) do
            term.setCursorPos(1, i)
            term.write(string.sub(l, 1, w))
        end
    end)
end

openModems()
startMesh()
draw()
local timer = os.startTimer(1)
while true do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "rednet_message" and ev[4] == PROTO then
        handle(ev[2], ev[3])
    elseif e == "modem_message" and not R.inferred then
        local p, d = ev[5], ev[6]
        if type(p) == "table" and p.sProtocol == PROTO and type(p.message) == "table"
            and p.message.mk == "basic" and type(d) == "number" and d > FAR then
            R.inferred = true
            updateKind()
        end
    elseif e == "peripheral" or e == "peripheral_detach" then
        openModems()
    elseif e == "timer" and ev[2] == timer then
        meshTick()
        draw()
        timer = os.startTimer(1)
    end
end
