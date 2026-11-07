-- Version: 1.1.0
-- TurtleMiner update guard (docs/MESH_UPDATE_PLAN.md section 3). Small and self-contained on
-- purpose: the startup files use it before anything else runs.
--   * applyJournal(j): swap staged files in, keeping <file>.bak; every step is written to
--     .tm_mesh/applying first, so a reboot in the middle finishes the same apply at next boot
--   * probation: after an update that changed running programs, .tm_mesh/probation lists the
--     files. guard.boot() counts boots; more than 2 extra reboots in probation, or a crash of
--     the program started with guard.run(), restores the .bak files, writes
--     .tm_mesh/rollback (tmmesh turns it into a signed bad mark) and reboots.
--   * probation ends after its time limit (computers 5 min) or when the program says so
--     (turtles: first trip home, or 10 min at home).
-- Usage in a startup: local G = loadfile("tmguard.lua")(); G.boot(); G.run("miner")

local G = {}
G.DIR = ".tm_mesh/"
local PROB, RB, JOURNAL = G.DIR .. "probation", G.DIR .. "rollback", G.DIR .. "applying"
G.MAX_BOOTS = 3   -- the restart right after the update + 2 more

local function now() return os.epoch("utc") end

local function readT(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    local ok, v = pcall(textutils.unserialize, s or "")
    if ok and type(v) == "table" then return v end
    return nil
end

-- Free bytes on the computer, or nil when unknown.
function G.free()
    local ok, n = pcall(fs.getFreeSpace, "/")
    return ok and type(n) == "number" and n or nil
end
G.MIN_FREE = 30000   -- keep this much free: below it old .bak copies are dropped

local function sizeOf(path)
    local ok, n = pcall(fs.getSize, path)
    return ok and n or 0
end

-- Frees space automatically: leftover .new/.tmp files, orphan staged files and, when still
-- short, the .bak copies of earlier versions (except those a running probation may restore).
-- want: free bytes to reach (default MIN_FREE). Returns bytes freed.
function G.reclaim(want)
    want = want or G.MIN_FREE
    local before = G.free()
    local keep = {}
    local prob = fs.exists(PROB) and (function()
        local f = fs.open(PROB, "r"); if not f then return nil end
        local str = f.readAll(); f.close()
        local ok, v = pcall(textutils.unserialize, str or "")
        return ok and type(v) == "table" and v or nil
    end)() or nil
    for _, it in ipairs(prob and prob.items or {}) do keep[it.path .. ".bak"] = true end
    local journal = fs.exists(JOURNAL)
    local function done() local f = G.free(); return f and f >= want end
    local function walk(dir, fn, depth)
        if depth > 3 then return end
        local ok, list = pcall(fs.list, dir)
        if not ok then return end
        for _, name in ipairs(list) do
            local path = (dir == "" or dir == "/") and name or (dir .. "/" .. name)
            if name ~= "rom" and path ~= "rom" then
                if fs.isDir(path) then walk(path, fn, depth + 1) else fn(path, name) end
            end
        end
    end
    -- 1. leftovers of interrupted writes (never while a journal is being applied)
    if not journal then
        walk("", function(path, name)
            if name:match("%.new$") or name:match("%.tmp$") then pcall(fs.delete, path) end
        end, 0)
    end
    -- 2. orphan staged files (tmmesh forgets the ones it no longer lists at its next scan)
    if not done() and not journal then
        local sd = G.DIR .. "stage"
        if fs.isDir(sd) then
            for _, name in ipairs(fs.list(sd)) do pcall(fs.delete, sd .. "/" .. name) end
        end
    end
    -- 3. old versions, biggest first, until enough is free
    if not done() then
        local baks = {}
        walk("", function(path, name)
            if name:match("%.bak$") and not keep[path] then baks[#baks + 1] = { path = path, size = sizeOf(path) } end
        end, 0)
        table.sort(baks, function(a, b) return a.size > b.size end)
        for _, b in ipairs(baks) do
            if done() then break end
            pcall(fs.delete, b.path)
        end
    end
    local after = G.free()
    return (before and after) and math.max(0, after - before) or 0
end

-- True when `need` bytes (plus the safety margin) can be written, reclaiming if necessary.
function G.ensure(need)
    local f = G.free()
    if not f then return true end
    if f >= need + G.MIN_FREE then return true end
    G.reclaim(need + G.MIN_FREE)
    f = G.free()
    return f == nil or f >= need + 2000
end

-- Atomic, never throws on a full disk: reclaims once and retries, else keeps the old file.
local function writeT(path, t)
    local text = textutils.serialize(t)
    for attempt = 1, 2 do
        local ok = pcall(function()
            if not fs.exists(G.DIR) then fs.makeDir(G.DIR) end
            local tmp = path .. ".tmp"
            if fs.exists(tmp) then fs.delete(tmp) end
            local f = fs.open(tmp, "w")
            if not f then error("open failed") end
            local wok, werr = pcall(f.write, text)
            f.close()
            if not wok then pcall(fs.delete, tmp); error(werr) end
            if fs.exists(path) then fs.delete(path) end
            fs.move(tmp, path)
        end)
        if ok then return true end
        if attempt == 1 then G.reclaim(#text + G.MIN_FREE) end
    end
    return false
end

function G.probation() return readT(PROB) end
function G.readRollback() return readT(RB) end
function G.clearRollback() if fs.exists(RB) then fs.delete(RB) end end
function G.pendingJournal() return fs.exists(JOURNAL) end
function G.passed() if fs.exists(PROB) then fs.delete(PROB) end end
-- The program ran fine for a while: a later restart (chunk unloaded, server restart, the player
-- rebooting it) is not a boot loop, so the boot count starts over. Only quick reboots add up.
function G.healthy()
    local p = readT(PROB)
    if p and (tonumber(p.boots) or 0) > 0 then p.boots = 0; writeT(PROB, p) end
end

-- j = {ids, items = {{path, stage}}, at, limit, kind, live}. Idempotent: safe to run again
-- on a journal that was cut short.
function G.applyJournal(j)
    if not j.started then
        -- Room for the staged copy, a .bak and the .new of every file, before touching anything.
        local need = 0
        for _, it in ipairs(j.items) do need = need + 2 * sizeOf(it.stage) end
        if not G.ensure(need) then error("not enough disk space to install the update (need " .. need .. " bytes)", 0) end
        j.started = true
    end
    if not writeT(JOURNAL, j) then error("cannot write the update journal (disk full?)", 0) end
    for _, it in ipairs(j.items) do
        if not it.done then
            if not it.bakDone then
                local bak = it.path .. ".bak"
                if fs.exists(it.path) then
                    if fs.exists(bak) then fs.delete(bak) end
                    fs.copy(it.path, bak)
                    it.fresh = false
                else
                    it.fresh = true
                end
                it.bakDone = true
                writeT(JOURNAL, j)
            end
            local dir = fs.getDir(it.path)
            if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
            local tmp = it.path .. ".new"
            if fs.exists(tmp) then fs.delete(tmp) end
            fs.copy(it.stage, tmp)
            if fs.exists(it.path) then fs.delete(it.path) end
            fs.move(tmp, it.path)
            it.done = true
            writeT(JOURNAL, j)
        end
    end
    if j.live then
        local p = { ids = j.ids, items = {}, at = j.at or now(), limit = j.limit, boots = 0, kind = j.kind }
        for _, it in ipairs(j.items) do
            if it.live ~= false then p.items[#p.items + 1] = { path = it.path, fresh = it.fresh } end
        end
        writeT(PROB, p)
    end
    fs.delete(JOURNAL)
    return true
end

-- Put the previous version back and reboot (noReboot: just restore).
function G.rollback(p, reason, noReboot)
    for _, it in ipairs(p.items or {}) do
        local bak = it.path .. ".bak"
        if it.fresh then
            if fs.exists(it.path) then fs.delete(it.path) end
        elseif fs.exists(bak) then
            if fs.exists(it.path) then fs.delete(it.path) end
            fs.copy(bak, it.path)
        end
    end
    writeT(RB, { ids = p.ids or {}, reason = tostring(reason or "?"):sub(1, 120), at = now() })
    if fs.exists(PROB) then fs.delete(PROB) end
    print("[update] " .. tostring(reason) .. ": back to the previous version")
    if not noReboot then
        if sleep then pcall(sleep, 1) end
        os.reboot()
    end
    return true
end

-- At boot, before the program: finish an interrupted apply, count probation boots.
function G.boot(journalOnly)
    local j = readT(JOURNAL)
    if j and type(j.items) == "table" then G.applyJournal(j) end
    if journalOnly then return end
    local p = G.probation()
    if not p then return end
    if p.limit and now() - (p.at or 0) >= p.limit then G.passed(); return end
    p.boots = (tonumber(p.boots) or 0) + 1
    if p.boots > G.MAX_BOOTS then
        G.rollback(p, "rebooted " .. (p.boots - 1) .. " times after the update")
        return
    end
    writeT(PROB, p)
end

-- Run a program like shell.run; a crash while on probation rolls back. Returns ok, err.
function G.run(prog, ...)
    local last
    local root = _G or _ENV
    local pe = root.printError
    root.printError = function(...)
        local a = { ... }
        last = tostring(a[1])
        if pe then return pe(...) end
    end
    local okR, ok = pcall(shell.run, prog, ...)
    root.printError = pe
    if not okR then last, ok = tostring(ok), false end
    if not ok and last ~= "Terminated" then
        local p = G.probation()
        if p then G.rollback(p, "crash: " .. tostring(last or "failed to start")) end
    end
    return ok, last
end

return G
