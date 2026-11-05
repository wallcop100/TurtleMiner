-- Version: 1.0.0
-- TurtleMiner crypto + message signing (docs/PROTOCOL.md "Signing"). Pure Lua, Lua 5.2
-- compatible (CC:Tweaked's Cobalt): no bitwise operators in the source.
--   * SHA-256, HMAC-SHA256 (with the key pads precomputed per key)
--   * canonical serialization of a message (sorted keys, fixed number format)
--   * signer(net): sign / check TMINER messages (`net` tag, `sig`, timestamp window)
--   * deriveKey(name, words): the network key from the join phrase (slowed down on purpose)
--   * loadNetwork / saveNetwork: the `.tm_network` file
-- Bit operations: CC's `bit32` library when present; else native operators compiled with
-- load() (Lua 5.3+, e.g. the simulator host); else plain arithmetic (slow, correct).
-- Usage: local C = require("tmcrypto")

local C = {}

-- ---------------------------------------------------------------------------
-- Bit operations
-- ---------------------------------------------------------------------------
local band, bor, bxor, bnot, rshift, lshift, rrotate
local M32 = 4294967296

local function useBit32(b)
    band, bor, bxor, bnot, rshift, lshift = b.band, b.bor, b.bxor, b.bnot, b.rshift, b.lshift
    rrotate = b.rrotate or function(x, n) return bor(rshift(x, n), lshift(x, 32 - n)) end
    C.BITS = "bit32"
end

local function useNative()
    if not load then return false end
    local ok, f = pcall(load, [[
        local M = 0xFFFFFFFF
        return {
            band = function(a, b) return a & b end,
            bor = function(a, b) return a | b end,
            bxor = function(a, b) return a ~ b end,
            bnot = function(a) return (~a) & M end,
            rshift = function(a, n) return (a & M) >> n end,
            lshift = function(a, n) return (a << n) & M end,
            rrotate = function(x, n) return ((x >> n) | (x << (32 - n))) & M end,
        }]], "=tmcrypto_native", "t", {})
    if not ok or type(f) ~= "function" then return false end
    local ok2, b = pcall(f)
    if not ok2 or type(b) ~= "table" then return false end
    band, bor, bxor, bnot, rshift, lshift, rrotate = b.band, b.bor, b.bxor, b.bnot, b.rshift, b.lshift, b.rrotate
    C.BITS = "native"
    return true
end

-- Arithmetic fallback: 4-bit lookup tables.
local function useArith()
    local XOR, AND = {}, {}
    for a = 0, 15 do
        for b = 0, 15 do
            local x, y, r1, r2, p = a, b, 0, 0, 1
            for _ = 1, 4 do
                local ba, bb = x % 2, y % 2
                if ba ~= bb then r1 = r1 + p end
                if ba == 1 and bb == 1 then r2 = r2 + p end
                x, y, p = (x - ba) / 2, (y - bb) / 2, p * 2
            end
            XOR[a * 16 + b], AND[a * 16 + b] = r1, r2
        end
    end
    local function op(T, a, b)
        local r, p = 0, 1
        for _ = 1, 8 do
            local na, nb = a % 16, b % 16
            r = r + T[na * 16 + nb] * p
            a, b, p = (a - na) / 16, (b - nb) / 16, p * 16
        end
        return r
    end
    band = function(a, b) return op(AND, a % M32, b % M32) end
    bxor = function(a, b) return op(XOR, a % M32, b % M32) end
    bnot = function(a) return 4294967295 - a % M32 end
    bor = function(a, b) a, b = a % M32, b % M32; return a + b - op(AND, a, b) end
    rshift = function(a, n) return math.floor((a % M32) / 2 ^ n) end
    lshift = function(a, n) return ((a % M32) * 2 ^ n) % M32 end
    rrotate = function(x, n)
        x = x % M32
        local lo = x % 2 ^ n
        return (x - lo) / 2 ^ n + lo * 2 ^ (32 - n)
    end
    C.BITS = "arith"
end

-- mode: nil = best available, or "bit32" / "native" / "arith" (tests)
function C.setBits(mode)
    local b32 = bit32
    if (mode == nil or mode == "bit32") and type(b32) == "table" and b32.bxor then useBit32(b32); return C.BITS end
    if (mode == nil or mode == "native") and useNative() then return C.BITS end
    useArith()
    return C.BITS
end
C.setBits()

-- ---------------------------------------------------------------------------
-- SHA-256
-- ---------------------------------------------------------------------------
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

local W = {}
local sbyte, schar, srep, sfmt = string.byte, string.char, string.rep, string.format
local unpack_ = table.unpack or unpack

-- One 64-byte block of `s` starting at index i, into state h (8 numbers, updated in place).
local function compress(h, s, i)
    for j = 1, 16 do
        local a, b, c, d = sbyte(s, i, i + 3)
        W[j] = ((a * 256 + b) * 256 + c) * 256 + d
        i = i + 4
    end
    for j = 17, 64 do
        local x, y = W[j - 15], W[j - 2]
        local s0 = bxor(bxor(rrotate(x, 7), rrotate(x, 18)), rshift(x, 3))
        local s1 = bxor(bxor(rrotate(y, 17), rrotate(y, 19)), rshift(y, 10))
        W[j] = (W[j - 16] + s0 + W[j - 7] + s1) % M32
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for j = 1, 64 do
        local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = (hh + S1 + ch + K[j] + W[j]) % M32
        local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
        local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
        local t2 = S0 + maj
        hh, g, f, e = g, f, e, (d + t1) % M32
        d, c, b, a = c, b, a, (t1 + t2) % M32
    end
    h[1], h[2], h[3], h[4] = (h[1] + a) % M32, (h[2] + b) % M32, (h[3] + c) % M32, (h[4] + d) % M32
    h[5], h[6], h[7], h[8] = (h[5] + e) % M32, (h[6] + f) % M32, (h[7] + g) % M32, (h[8] + hh) % M32
end

C.blocks = 0   -- compressions done (cost counter for tests)

-- Hash `s` continuing from state `init` that already absorbed `prefix` bytes (0 or 64).
local function digest(init, prefix, s)
    local h = { init[1], init[2], init[3], init[4], init[5], init[6], init[7], init[8] }
    local len = #s
    local total = prefix + len
    local bits = total * 8
    local lenBytes = {}
    for k = 8, 1, -1 do
        local b = bits % 256
        lenBytes[k] = b
        bits = (bits - b) / 256
    end
    local padLen = 64 - ((total + 9) % 64)
    if padLen == 64 then padLen = 0 end
    local full = len - len % 64
    for i = 1, full, 64 do compress(h, s, i) end
    local tail = s:sub(full + 1) .. "\128" .. srep("\0", padLen) .. schar(unpack_(lenBytes))
    for i = 1, #tail, 64 do compress(h, tail, i) end
    C.blocks = C.blocks + full / 64 + #tail / 64
    return h
end

local function toBytes(h)
    local out = {}
    for i = 1, 8 do
        local v = h[i]
        local b4 = v % 256; v = (v - b4) / 256
        local b3 = v % 256; v = (v - b3) / 256
        local b2 = v % 256; v = (v - b2) / 256
        out[i] = schar(v, b2, b3, b4)
    end
    return table.concat(out)
end

local function toHex(s)
    return (s:gsub(".", function(c) return sfmt("%02x", sbyte(c)) end))
end
C.toHex = toHex

function C.sha256(s) return toBytes(digest(H0, 0, s)) end
function C.sha256hex(s) return toHex(C.sha256(s)) end

-- HMAC with the key pads hashed once: returns fn(msg) -> raw 32 bytes.
function C.hmacFn(key)
    if #key > 64 then key = C.sha256(key) end
    key = key .. srep("\0", 64 - #key)
    local ip, op = {}, {}
    for i = 1, 64 do
        local k = sbyte(key, i)
        ip[i] = schar(bxor(k, 0x36))
        op[i] = schar(bxor(k, 0x5c))
    end
    local ih = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
    local oh = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
    compress(ih, table.concat(ip), 1)
    compress(oh, table.concat(op), 1)
    C.blocks = C.blocks + 2
    return function(msg)
        return toBytes(digest(oh, 64, toBytes(digest(ih, 64, msg))))
    end
end

function C.hmac(key, msg) return C.hmacFn(key)(msg) end
function C.hmacHex(key, msg) return toHex(C.hmac(key, msg)) end

-- ---------------------------------------------------------------------------
-- Canonical serialization: same bytes on every computer for the same message.
--   string "s<len>:<bytes>", number "n<int or %.17g>;", true "T", false "F",
--   table "{" .. (key value)* .. "}" with keys sorted by their encoding.
-- Functions / other types are skipped. Top level: the MUTABLE fields are left out.
-- ---------------------------------------------------------------------------
C.MUTABLE = { sig = true, hops = true, hop = true, via = true, mk = true }

local function encNum(v)
    if v ~= v then return "nnan;" end
    if v == math.huge then return "ninf;" end
    if v == -math.huge then return "n-inf;" end
    if v == math.floor(v) and v > -9007199254740992 and v < 9007199254740992 then
        return sfmt("n%d;", v)
    end
    return "n" .. sfmt("%.17g", v) .. ";"
end

local enc
enc = function(v, out, depth, skip)
    local t = type(v)
    if t == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif t == "number" then
        out[#out + 1] = encNum(v)
    elseif t == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif t == "table" then
        if depth > 32 then out[#out + 1] = "?"; return end
        local items = {}
        for k, x in pairs(v) do
            local tk, tx = type(k), type(x)
            if not (skip and skip[k]) and (tk == "string" or tk == "number" or tk == "boolean")
                and (tx == "string" or tx == "number" or tx == "boolean" or tx == "table") then
                local ko = {}
                enc(k, ko, depth + 1)
                items[#items + 1] = { table.concat(ko), x }
            end
        end
        table.sort(items, function(a, b) return a[1] < b[1] end)
        out[#out + 1] = "{"
        for _, it in ipairs(items) do
            out[#out + 1] = it[1]
            enc(it[2], out, depth + 1)
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = "x"
    end
end

function C.canon(msg)
    local out = {}
    enc(msg, out, 0, C.MUTABLE)
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Signer
-- ---------------------------------------------------------------------------
C.WINDOW_MS = 600000         -- reject messages older / newer than this (10 min)
C.SIG_HEX = 32               -- hex chars of the HMAC kept in `sig` (128 bits)
-- Kinds whose own body carries signed timestamps: not too old by the envelope's ts.
C.OLD_OK = { catchup = true }

function C.netTag(key) return C.sha256hex("tmnet|" .. key):sub(1, 8) end

-- net = {name, key (64 hex)}. Returns signer {tag, sign(msg), check(msg, nowMs) -> ok, why}.
function C.signer(net)
    if type(net) ~= "table" or type(net.key) ~= "string" or #net.key < 16 then return nil end
    local mac = C.hmacFn(net.key)
    local tag = C.netTag(net.key)
    local S = { tag = tag, name = net.name }
    function S.mac(msg) return toHex(mac(C.canon(msg))):sub(1, C.SIG_HEX) end
    function S.sign(msg)
        msg.net = tag
        msg.sig = nil
        msg.sig = S.mac(msg)
        return msg
    end
    -- Cheap tests first: network tag, signature present, timestamp window; then the HMAC.
    function S.check(msg, nowMs)
        if type(msg) ~= "table" then return false, "garbage" end
        if msg.net ~= tag then return false, msg.net == nil and "unsigned" or "foreign" end
        if type(msg.sig) ~= "string" then return false, "unsigned" end
        local ts = tonumber(msg.ts)
        if nowMs and ts then
            if ts > nowMs + C.WINDOW_MS then return false, "future" end
            if ts < nowMs - C.WINDOW_MS and not C.OLD_OK[msg.kind] then return false, "old" end
        elseif nowMs and not ts then
            return false, "no ts"
        end
        if S.mac(msg) ~= msg.sig then return false, "bad sig" end
        return true
    end
    return S
end

-- ---------------------------------------------------------------------------
-- Network key from the join phrase. Deliberately slow (ITER hash rounds) so each guess of
-- a phrase costs the attacker the same (~0.2 s in the sim with its bit32 shim, about 1 s on a
-- CC computer; measured in test scenario 52). yield(): called every
-- 256 rounds (CC kills code that runs > ~7 s without yielding).
-- ---------------------------------------------------------------------------
C.KDF_ITER = 1024

function C.normName(name)
    name = tostring(name or ""):lower():gsub("[^%w_%-]", "")
    if name == "" then name = "mine" end
    return name:sub(1, 16)
end

function C.deriveKey(name, words, yield, iter)
    name = C.normName(name)
    local phrase = table.concat(words, " ")
    local salt = "tminer-net-v1|" .. name .. "|"
    local h = C.sha256(salt .. phrase)
    for i = 1, iter or C.KDF_ITER do
        h = C.sha256(h .. salt)
        if yield and i % 256 == 0 then yield() end
    end
    return toHex(h)
end

-- ---------------------------------------------------------------------------
-- .tm_network file: { name, words = {4 words}, key = 64 hex }
-- ---------------------------------------------------------------------------
C.NET_FILE = ".tm_network"

local function unser(s)
    if textutils and textutils.unserialize then return textutils.unserialize(s) end
    local fn = load and load("return " .. s, "=net", "t", {})
    if fn then local ok, v = pcall(fn); if ok then return v end end
    return nil
end

function C.validNetwork(n)
    return type(n) == "table" and type(n.key) == "string" and #n.key == 64 and not n.key:find("[^0-9a-f]")
        and type(n.name) == "string"
end

function C.loadNetwork(path)
    path = path or C.NET_FILE
    if not (fs and fs.exists(path)) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    local n = s and unser(s)
    if C.validNetwork(n) then return n end
    return nil
end

function C.serializeNetwork(n)
    local w = {}
    for i, x in ipairs(n.words or {}) do w[i] = sfmt("%q", x) end
    return "{\n  name = " .. sfmt("%q", n.name) .. ",\n  words = { " .. table.concat(w, ", ") .. " },\n  key = "
        .. sfmt("%q", n.key) .. ",\n}\n"
end

function C.saveNetwork(n, path)
    path = path or C.NET_FILE
    local tmp = path .. ".tmp"
    local f = fs.open(tmp, "w")
    if not f then return false, "can't write " .. path end
    f.write(C.serializeNetwork(n))
    f.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
end

return C
