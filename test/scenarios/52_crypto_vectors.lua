-- Version: 1.0.0
-- Scenario 52 (MU-0): the signing building blocks, run inside a sim computer (CC-like env:
-- Lua 5.2 surface, `bit32` library) and on the host with the pure-arithmetic fallback.
--  A: SHA-256 test vectors ("", "abc", the 448-bit message, 1 million 'a' on the host);
--     HMAC-SHA256 RFC 4231 cases 1, 2, 4, 6, 7
--  B: canonical form is deterministic (key order, float/int formatting) and skips the
--     fields relays change; tampering any signed field breaks the signature
--  C: cost: HMAC of a typical status message (blocks + host ms) and the key derivation
--  D: word list: 1024 unique 3-6 letter words, no two one edit apart; phrases parse with
--     any case / separators; a typo names the closest word
local VEC = {
    { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
    { "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
}
local function hx(s) return (s:gsub("..", function(h) return string.char(tonumber(h, 16)) end)) end
local HMAC = {   -- RFC 4231: key, data, HMAC-SHA-256
    { string.rep("\11", 20), "Hi There", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7" },
    { "Jefe", "what do ya want for nothing?", "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" },
    { hx("0102030405060708090a0b0c0d0e0f10111213141516171819"), string.rep("\205", 50),
      "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b" },
    { string.rep("\170", 131), "Test Using Larger Than Block-Size Key - Hash Key First",
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54" },
    { string.rep("\170", 131), "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.",
      "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2" },
}

local STATUS = {
    v = 1, kind = "status", from = 12, to = "server", boot = 1793000000000, seq = 4711, ts = 1793000123456,
    hops = 0, hop = 2, ohop = 2, via = 7, mk = "basic",
    label = "Miner-3", version = "1.4.2", phase = "MINING", reason = nil,
    pos = { x = -1234, y = -58, z = 4567 }, facing = 1, home = { x = 100, y = 64, z = -20 }, gps = true,
    fuel = 18342, fuelNeeded = 1520, slotsUsed = 7,
    job = { corridor = 3, branch = 11, side = "L", step = 14 },
    stats = { ores = 214, blocks = 9120, trips = 12, uptime = 18234 }, cfg = { targetY = -58, focus = "diamond" },
}

return {
    title = "SHA-256 / HMAC vectors, canonical form, cost, join words",
    needs = { "tmcrypto", "tmwords" },
    run = function(sim, H)
        -- A + B + C inside a sim computer (bit32 like CC) ---------------------------
        local c = sim.computer({ id = 1, modem = false })
        H.installShared(c)
        local out
        sim.boot(c, function(G)
            local C = assert(G.loadfile("tmcrypto.lua", nil, G))()
            local r = { bits = C.BITS, bad = {} }
            for _, v in ipairs(VEC) do
                if C.sha256hex(v[1]) ~= v[2] then r.bad[#r.bad + 1] = "sha " .. #v[1] end
            end
            for i, v in ipairs(HMAC) do
                if C.hmacHex(v[1], v[2]) ~= v[3] then r.bad[#r.bad + 1] = "hmac case " .. i end
            end
            -- B: canonical form
            local a = C.canon({ b = 1, a = { 3, 2.5, "x" }, c = true })
            local b = C.canon({ c = true, a = { 3, 2.5, "x" }, b = 1.0 })
            r.canonSame = a == b
            local m1 = {}
            for k, v in pairs(STATUS) do m1[k] = v end
            local m2 = {}
            for k, v in pairs(STATUS) do m2[k] = v end
            m2.hops, m2.hop, m2.via, m2.mk = 3, 0, 99, "ender"
            r.mutableSkipped = C.canon(m1) == C.canon(m2)
            local net = { name = "sim", key = string.rep("ab", 32) }
            local S = C.signer(net)
            S.sign(m1)
            r.verifies = S.check(m1, m1.ts + 1000) == true
            m1.hops, m1.hop = 2, 1
            r.relayedVerifies = S.check(m1, m1.ts) == true
            local tamper = {}
            for _, f in ipairs({ "phase", "from", "to", "seq", "ts", "ohop", "net" }) do
                local saved = m1[f]
                m1[f] = (type(saved) == "number") and (saved + 1) or (tostring(saved) .. "x")
                local ok = S.check(m1, STATUS.ts)
                if ok then tamper[#tamper + 1] = f end
                m1[f] = saved
            end
            m1.pos.x = m1.pos.x + 1
            if S.check(m1, STATUS.ts) then tamper[#tamper + 1] = "pos.x" end
            m1.pos.x = m1.pos.x - 1
            r.tamperAccepted = tamper
            r.restored = S.check(m1, STATUS.ts) == true
            -- C: cost of one status HMAC (with precomputed pads) and the key derivation
            local plain = {}
            for k, v in pairs(STATUS) do plain[k] = v end
            local n0 = C.blocks
            S.sign(plain)
            r.statusBlocks = C.blocks - n0
            r.canonLen = #C.canon(plain)
            n0 = C.blocks
            C.deriveKey("sim", { "lava", "oak", "ember", "pick" })
            r.kdfBlocks = C.blocks - n0
            out = r
        end, { background = true })
        sim.run({ maxTime = 5 })
        H.check(out, "crypto program did not finish: %s", tostring(c.err))
        H.check(out.bits == "bit32", "sim computer used %s, not bit32", tostring(out.bits))
        H.check(#out.bad == 0, "test vectors failed (bit32): %s", table.concat(out.bad, ", "))
        H.check(out.canonSame, "canonical form depends on key order / 1 vs 1.0")
        H.check(out.mutableSkipped, "canonical form covers a field relays change")
        H.check(out.verifies and out.relayedVerifies, "signed message does not verify (relayed copy %s)", tostring(out.relayedVerifies))
        H.check(#out.tamperAccepted == 0, "tampered fields still verify: %s", table.concat(out.tamperAccepted, ", "))
        H.check(out.restored, "restored message no longer verifies")

        -- Host: arithmetic fallback (no bit32, no native operators) and the long vector.
        local C = dofile(sim.REPO .. "/miner/tmcrypto.lua")
        C.setBits("arith")
        for _, v in ipairs(VEC) do H.check(C.sha256hex(v[1]) == v[2], "arith sha256 of %d bytes", #v[1]) end
        for i, v in ipairs(HMAC) do H.check(C.hmacHex(v[1], v[2]) == v[3], "arith hmac case %d", i) end
        C.setBits("native")
        H.check(C.sha256hex(string.rep("a", 1000000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
            "sha256 of one million 'a'")
        -- Host timing of the same work with the sim's bit32 shim (closest to CC's library).
        C.setBits("bit32")
        local b32 = c.env.bit32
        _G.bit32 = b32
        C.setBits("bit32")
        local S = C.signer({ name = "sim", key = string.rep("ab", 32) })
        local msg = {}
        for k, v in pairs(STATUS) do msg[k] = v end
        local N = 200
        local t0 = os.clock()
        for _ = 1, N do S.sign(msg) end
        local msSign = (os.clock() - t0) / N * 1000
        t0 = os.clock()
        C.deriveKey("sim", { "lava", "oak", "ember", "pick" })
        local msKdf = (os.clock() - t0) * 1000
        _G.bit32 = nil

        -- D: words -------------------------------------------------------------------
        local Wd = dofile(sim.REPO .. "/miner/tmwords.lua")
        H.check(#Wd.LIST == 1024, "word list has %d words", #Wd.LIST)
        local seen = {}
        for _, w in ipairs(Wd.LIST) do
            H.check(w:match("^%l%l%l%l?%l?%l?$"), "bad word %q", w)
            H.check(not seen[w], "duplicate word %q", w)
            seen[w] = true
        end
        -- no two words one edit apart (check by generating every 1-edit variant)
        local letters = "abcdefghijklmnopqrstuvwxyz"
        for _, w in ipairs(Wd.LIST) do
            for i = 1, #w do
                local del = w:sub(1, i - 1) .. w:sub(i + 1)
                H.check(not seen[del] or del == w, "%q and %q differ by one letter", w, del)
                for j = 1, 26 do
                    local ch = letters:sub(j, j)
                    local sub = w:sub(1, i - 1) .. ch .. w:sub(i + 1)
                    H.check(sub == w or not seen[sub], "%q and %q differ by one letter", w, sub)
                end
                if i < #w then
                    local sw = w:sub(1, i - 1) .. w:sub(i + 1, i + 1) .. w:sub(i, i) .. w:sub(i + 2)
                    H.check(sw == w or not seen[sw], "%q and %q differ by a swap", w, sw)
                end
            end
        end
        local p = Wd.parse("  LAVA,oak   Ember-pick ")
        H.check(p and table.concat(p, " ") == "lava oak ember pick", "phrase with odd case/spacing not parsed")
        local bad, err, word, sug = Wd.parse("lava oak embr pick")
        H.check(not bad and word == "embr" and sug == "ember" and err:find("did you mean 'ember'", 1, true),
            "typo not caught / wrong suggestion: %s", tostring(err))
        local _, err3 = Wd.parse("lava oak ember")
        H.check(err3 and err3:find("need 4 words", 1, true), "3 words accepted: %s", tostring(err3))
        local _, err5 = Wd.parse("lava oak ember pick")
        H.check(err5 == nil, "valid phrase rejected")

        H.note(string.format("vectors ok (bit32 in sim, arith fallback, native); status msg %d B canonical = %d SHA blocks,"
            .. " %.2f ms/sign on host; key derivation %d blocks, %.0f ms on host; 1024 words, none 1 edit apart",
            out.canonLen, out.statusBlocks, msSign, out.kdfBlocks, msKdf))
    end,
}
