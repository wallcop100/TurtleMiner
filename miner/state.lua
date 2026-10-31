-- Version: 1.0.0
-- TurtleMiner persistent state: atomic snapshot + append-only move journal.
--
-- Files (turtle root):
--   .tm_state        snapshot (serialized st table)
--   .tm_state.tmp    snapshot being written; used on load if the main file is missing/corrupt
--   .tm_journal      journal, one record per line
--   .tm_journal.tmp  journal being rewritten by state.save
--
-- Journal records (space separated, tag first):
--   I <op> <fuel>                        intent, written before a move/turn (op: f b u d l r)
--   D <x> <y> <z> <facing> <fuel>        done, written after the op (also after a failed op,
--                                        with the unchanged position, to close the intent)
--   R <fuel>                             fuel after a refuel
--   S <x> <y> <z> <facing> <fuel> <seq>  snapshot marker; <seq> = st.saveSeq of that snapshot
-- Fuel "unlimited" is written as -1 and read back as "unlimited".
--
-- state.save keeps the last HISTORY_KEEP D/R/S lines in front of the new S line, so a world
-- rollback (server crash) that goes back past a snapshot can still be matched by fuel.
-- Lines after the S whose seq equals st.saveSeq are replayed on recovery; older lines are
-- history only.
--
-- Fields added to st by this module: saveSeq (int), saveFuel (number|"unlimited").

local state = {}

local STATE       = ".tm_state"
local STATE_TMP   = ".tm_state.tmp"
local JOURNAL     = ".tm_journal"
local JOURNAL_TMP = ".tm_journal.tmp"

local HISTORY_KEEP = 1000   -- D/R/S lines carried over on each save
local MAX_LINES    = 2000   -- logDone forces a save past this

local journalLines = nil    -- lines currently in the journal; nil = not counted yet

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

local function fuelNow()
    if turtle and turtle.getFuelLevel then return turtle.getFuelLevel() end
    return "unlimited"
end

local function encFuel(f)
    if type(f) ~= "number" then return -1 end
    return math.floor(f)
end

local function decFuel(n)
    if n == nil then return nil end
    if n < 0 then return "unlimited" end
    return n
end

local function fmtNum(n)
    return string.format("%d", math.floor(n))
end

local function serialize(v, out, depth)
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "nil"
        else
            out[#out + 1] = string.format("%.17g", v)
        end
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "table" then
        if depth > 16 then out[#out + 1] = "nil"; return end
        out[#out + 1] = "{"
        for k, val in pairs(v) do
            local kt, vt = type(k), type(val)
            if (kt == "string" or kt == "number" or kt == "boolean")
                and (vt == "string" or vt == "number" or vt == "boolean" or vt == "table") then
                out[#out + 1] = "["
                serialize(k, out, depth + 1)
                out[#out + 1] = "]="
                serialize(val, out, depth + 1)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = "nil"
    end
end

local function encode(v)
    local out = {}
    serialize(v, out, 0)
    return table.concat(out)
end

local function decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local fn = load("return " .. s, "=tm_state", "t", {})
    if not fn then return nil end
    local ok, v = pcall(fn)
    if ok and type(v) == "table" then return v end
    return nil
end

local function isPos(p)
    return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number"
        and type(p.z) == "number"
end

local function valid(st)
    return type(st) == "table" and st.schema == 1 and isPos(st.pos) and isPos(st.home)
        and type(st.facing) == "number" and type(st.homeFacing) == "number"
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local ok, s = pcall(h.readAll)
    pcall(h.close)
    if ok then return s end
    return nil
end

local function writeFile(path, s)
    local ok, err = pcall(function()
        local h, e = fs.open(path, "w")
        if not h then error(e or "open failed", 0) end
        h.write(s)
        h.close()
    end)
    return ok, err
end

-- delete dst, move src -> dst. Returns ok.
local function replace(src, dst)
    return (pcall(function()
        if fs.exists(dst) then fs.delete(dst) end
        fs.move(src, dst)
    end))
end

local function readLines(path)
    local s = readFile(path)
    local lines = {}
    if not s then return lines end
    for line in string.gmatch(s, "[^\n]+") do
        if line ~= "" then lines[#lines + 1] = line end
    end
    return lines
end

local function journalPath()
    if fs.exists(JOURNAL) then return JOURNAL end
    if fs.exists(JOURNAL_TMP) then return JOURNAL_TMP end
    return JOURNAL
end

local function append(line)
    local ok = pcall(function()
        local h = fs.open(JOURNAL, "a")
        if not h then error("open failed", 0) end
        h.write(line .. "\n")
        h.close()
    end)
    if journalLines == nil then
        journalLines = #readLines(JOURNAL)
    elseif ok then
        journalLines = journalLines + 1
    end
    return ok
end

local function parseLine(line)
    local f = {}
    for w in string.gmatch(line, "%S+") do f[#f + 1] = w end
    local tag = f[1]
    if tag == "I" then
        local fuel = tonumber(f[3])
        if not f[2] or not fuel then return nil end
        return { tag = "I", op = f[2], fuel = decFuel(fuel) }
    elseif tag == "D" or tag == "S" then
        local x, y, z, fc, fuel = tonumber(f[2]), tonumber(f[3]), tonumber(f[4]),
            tonumber(f[5]), tonumber(f[6])
        if not (x and y and z and fc and fuel) then return nil end
        local e = { tag = tag, x = x, y = y, z = z, facing = fc, fuel = decFuel(fuel) }
        if tag == "S" then
            e.seq = tonumber(f[7])
            if not e.seq then return nil end
        end
        return e
    elseif tag == "R" then
        local fuel = tonumber(f[2])
        if not fuel then return nil end
        return { tag = "R", fuel = decFuel(fuel) }
    end
    return nil
end

----------------------------------------------------------------------------
-- public API
----------------------------------------------------------------------------

function state.new(home, homeFacing, gps)
    home = home or { x = 0, y = 0, z = 0 }
    local h = { x = math.floor(home.x), y = math.floor(home.y), z = math.floor(home.z) }
    local f = math.floor(homeFacing or 0) % 4
    local started = 0
    if os and os.epoch then started = os.epoch("utc") end
    return {
        schema     = 1,
        pos        = { x = h.x, y = h.y, z = h.z },
        facing     = f,
        home       = h,
        homeFacing = f,
        gps        = gps and true or false,
        phase      = "BOOT",
        reason     = nil,
        job        = { corridor = 0, branch = 0, side = "L", step = 0 },
        flags      = { resetJob = false, update = false },
        stats      = { ores = 0, blocks = 0, trips = 0, started = started },
        lastError  = nil,
        saveSeq    = 0,
    }
end

-- Loads the newest valid snapshot (.tm_state or .tm_state.tmp). nil if neither parses.
function state.load()
    local a = decode(readFile(STATE))
    if not valid(a) then a = nil end
    local b = decode(readFile(STATE_TMP))
    if not valid(b) then b = nil end
    if a and b then
        -- tmp only survives when a crash hit between writing it and moving it: it is newer
        if (b.saveSeq or 0) > (a.saveSeq or 0) then return b end
        return a
    end
    return a or b
end

-- Atomic snapshot, then rewrite the journal as <history> + "S" line.
function state.save(st)
    if type(st) ~= "table" then return false end
    st.saveSeq = (st.saveSeq or 0) + 1
    local fuel = fuelNow()
    st.saveFuel = fuel
    local data = encode(st)
    if not writeFile(STATE_TMP, data) then return false end
    -- verify before replacing the good copy (disk full gives a truncated file)
    if not valid(decode(readFile(STATE_TMP))) then
        pcall(fs.delete, STATE_TMP)
        return false
    end
    if not replace(STATE_TMP, STATE) then return false end

    -- journal: keep history (no I lines), then the new S line
    local old = readLines(journalPath())
    local hist = {}
    for i = 1, #old do
        local t = string.sub(old[i], 1, 1)
        if (t == "D" or t == "R" or t == "S") and parseLine(old[i]) then
            hist[#hist + 1] = old[i]
        end
    end
    local first = #hist - HISTORY_KEEP + 1
    if first < 1 then first = 1 end
    local out = {}
    for i = first, #hist do out[#out + 1] = hist[i] end
    out[#out + 1] = "S " .. fmtNum(st.pos.x) .. " " .. fmtNum(st.pos.y) .. " " .. fmtNum(st.pos.z)
        .. " " .. fmtNum(st.facing) .. " " .. fmtNum(encFuel(fuel)) .. " " .. fmtNum(st.saveSeq)
    if not writeFile(JOURNAL_TMP, table.concat(out, "\n") .. "\n") then return true end
    replace(JOURNAL_TMP, JOURNAL)
    journalLines = #out
    return true
end

function state.wipe()
    for _, p in ipairs({ STATE, STATE_TMP, JOURNAL, JOURNAL_TMP }) do
        if fs.exists(p) then pcall(fs.delete, p) end
    end
    journalLines = 0
end

function state.logIntent(op, fuel)
    return append("I " .. tostring(op) .. " " .. fmtNum(encFuel(fuel)))
end

function state.logDone(st, fuel)
    local ok = append("D " .. fmtNum(st.pos.x) .. " " .. fmtNum(st.pos.y) .. " " .. fmtNum(st.pos.z)
        .. " " .. fmtNum(st.facing) .. " " .. fmtNum(encFuel(fuel)))
    if journalLines and journalLines > MAX_LINES then state.save(st) end
    return ok
end

function state.logRefuel(fuel)
    return append("R " .. fmtNum(encFuel(fuel)))
end

-- Parsed journal entries, oldest first. Malformed lines are skipped.
function state.readJournal()
    local lines = readLines(journalPath())
    local entries = {}
    for i = 1, #lines do
        local e = parseLine(lines[i])
        if e then entries[#entries + 1] = e end
    end
    journalLines = #lines
    return entries
end

return state
