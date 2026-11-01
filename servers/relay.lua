-- Version: 1.1.0
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
        }
        if R.wireless + R.wired == 0 then lines[2] = "NO MODEM: attach one" end
        for i, l in ipairs(lines) do
            term.setCursorPos(1, i)
            term.write(string.sub(l, 1, w))
        end
    end)
end

openModems()
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
        draw()
        timer = os.startTimer(1)
    end
end
