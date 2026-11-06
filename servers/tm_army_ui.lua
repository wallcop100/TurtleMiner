-- Version: 1.1.0
-- TurtleMiner server UI, army pages (docs/ARMY_PLAN.md "UI / UX"): NET > ARMY list, the New wizard
-- (name, station X Y Z, facing, ore presets -> levels), the army page with tabs MAP / TRAFFIC /
-- STATS / SETTINGS, RELEASE of a silent turtle's claim, and the turtle-card JOIN picker.
-- Keyboard first (arrows / Tab / Enter / Backspace, typed digits), no colour, mouse or touch needed;
-- every write goes through U.put so nothing is drawn off screen. Talks to the coordinator
-- (tm_army.lua) with army_new / army_set / army_release on the leader.
local T = ...
local S = T.S
local U = T.ui
local trunc = T.trunc
local put, button, header, buttonGrid = U.put, U.button, U.header, U.buttonGrid
local fl = math.floor

local ORES = { "diamond", "redstone", "lapis", "gold", "iron", "copper", "coal", "emerald", "ancient_debris" }
local FACES = { { "N", 0 }, { "E", 1 }, { "S", 2 }, { "W", 3 } }
local FACE_NAME = { [0] = "N", "E", "S", "W" }
local TABS = { { "map", "MAP", "MAP" }, { "traf", "TRAF", "TRAFFIC" }, { "stats", "STAT", "STATS" },
    { "set", "SET", "SETTINGS" } }
local STEPN = { "name", "x", "y", "z", "face", "ores", "go" }
local DVEC = { [0] = { 0, -1 }, [1] = { 1, 0 }, [2] = { 0, 1 }, [3] = { -1, 0 } }
local ARROW = { [0] = "v", ">", "^", "<" }   -- facing relative to the station frame (forward = down the screen)
local ZOOMS = { 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64 }
local PRIO = { [" "] = 0, ["-"] = 1, ["|"] = 1, ["#"] = 2, ["."] = 3, ["+"] = 4, S = 8, ["^"] = 9, ["v"] = 9, [">"] = 9, ["<"] = 9 }
local CCOL = { ["#"] = colors.green, ["+"] = colors.yellow, ["."] = colors.lightGray, S = colors.white,
    ["-"] = colors.gray, ["|"] = colors.gray, ["^"] = colors.cyan, v = colors.cyan, [">"] = colors.cyan, ["<"] = colors.cyan }

local function names()
    local n = {}
    for k in pairs(S.armies or {}) do n[#n + 1] = k end
    table.sort(n)
    return n
end

local function cur(ui)
    local st = ui.army
    return st and S.armies and S.armies[st.name] or nil, st
end

-- Send a message to the coordinator (on a replica it is forwarded to the leader; true = sent). Returns the result or nil, error.
local function send(kind, body)
    if not T.army then return nil, "no army module" end
    body.kind, body.from = kind, S.myId
    if T.isLeader and not T.isLeader() then
        if not T.forwardArmy then return nil, "no leader" end
        return T.forwardArmy(body)
    end
    local a, err = T.army.handle(body)
    if T.markDirty then T.markDirty() end
    if a == nil then return nil, err or "refused" end
    return a
end

local function span(ms)
    local s = fl(math.abs(ms) / 1000)
    if s < 60 then return s .. "s" end
    if s < 3600 then return fl(s / 60) .. "m" end
    return fl(s / 3600) .. "h"
end

local function silent(tid)
    local r = S.turtles[tid]
    if not r then return true end
    local t = T.now()
    if T.isAway and T.isAway(r, t) then return false end
    if r.alert == "SILENT" or r.alert == "OVERDUE" then return true end
    return t - (r.lastSeen or 0) > (T.SILENT_MS or 120000)
end

local function sortedKeys(t)
    local k = {}
    for key in pairs(t) do k[#k + 1] = key end
    table.sort(k, function(a, b) return tostring(a) < tostring(b) end)
    return k
end

local function ids(t)
    local o = {}
    for id in pairs(t or {}) do o[#o + 1] = id end
    table.sort(o)
    local s = {}
    for _, id in ipairs(o) do s[#s + 1] = "#" .. id end
    return table.concat(s, " ")
end

-- ---------------------------------------------------------------------------
-- Number / text entry (shared by the wizard and the level entry)
-- ---------------------------------------------------------------------------
local function tabState(ui)
    if ui.view == "armywiz" and ui.wz then return ui.wz end
    return ui.army or {}
end

local function entryChar(ui, spec, ch)
    local inp = ui.input or ""
    if spec.text then
        if ch:match("^[%w_%-]$") and #inp < (spec.max or 12) then ui.input = inp .. ch end
    elseif ch == "DEL" then ui.input = inp:sub(1, -2)
    elseif ch == "-" then
        if inp:sub(1, 1) == "-" then ui.input = inp:sub(2) else ui.input = "-" .. inp end
    elseif ch:match("^%d$") and #inp:gsub("^%-", "") < 8 then ui.input = inp .. ch end
    ui.msg = nil
    tabState(ui).tabbed = false
end

local function entryOk(ui, spec)
    ui.msg = nil
    if spec.text then
        ui.msg = spec.ok(ui.input or "")
        return
    end
    local v = tonumber(ui.input)
    if not v or v ~= fl(v) then ui.msg = "Need a whole number"; return end
    if v < spec.lo or v > spec.hi then ui.msg = "Range " .. spec.lo .. ".." .. spec.hi; return end
    ui.msg = spec.ok(v)
end

local function renderEntry(ui, title, spec, tag)
    header(ui, title, tag, false)
    put(ui, 1, 2, trunc(spec.prompt, ui.w), colors.lightGray)
    put(ui, 1, 3, "> " .. (ui.input or "") .. "_", colors.yellow)
    if ui.msg then put(ui, 1, 4, trunc(ui.msg, ui.w), colors.red)
    elseif spec.hint then put(ui, 1, 4, trunc(spec.hint, ui.w), colors.gray) end
    local function ok() entryOk(ui, spec) end
    if spec.text or ui.h < 11 then
        local defs = {}
        for _, d in ipairs(spec.extra or {}) do defs[#defs + 1] = d end
        defs[#defs + 1] = { "OK", colors.green, ok }
        if not spec.text then
            defs[#defs + 1] = { "DEL", colors.gray, function() entryChar(ui, spec, "DEL") end }
            defs[#defs + 1] = { "-", colors.gray, function() entryChar(ui, spec, "-") end }
        end
        defs[#defs + 1] = { "BACK", colors.red, function() T.back(ui) end }
        buttonGrid(ui, defs, 4, 3)
        return
    end
    local defs = {}
    for _, k in ipairs({ "7", "8", "9", "DEL", "4", "5", "6", "-", "1", "2", "3", "0" }) do
        defs[#defs + 1] = { k, colors.gray, function() entryChar(ui, spec, k) end }
    end
    defs[#defs + 1] = { "BACK", colors.red, function() T.back(ui) end }
    defs[#defs + 1] = { "", colors.black, nil }
    defs[#defs + 1] = { "", colors.black, nil }
    defs[#defs + 1] = { "OK", colors.green, ok }
    local bw = math.max(1, fl((ui.w - 5) / 4))
    local gap = (ui.h >= 15) and 1 or 0
    local top = ui.h - (4 * (1 + gap) - gap) + 1
    for i, d in ipairs(defs) do
        local c, rr = (i - 1) % 4, fl((i - 1) / 4)
        if d[3] then button(ui, 2 + c * (bw + 1), top + rr * (1 + gap), bw, d[1], d[2], d[3]) end
    end
end

-- ---------------------------------------------------------------------------
-- Wizard
-- ---------------------------------------------------------------------------
local function wzGoto(ui, n)
    local wz = ui.wz
    wz.step, wz.tabbed, ui.msg = n, false, nil
    local s = STEPN[n]
    if s == "name" then ui.input = wz.name or ""
    elseif s == "x" or s == "y" or s == "z" then ui.input = wz[s] ~= nil and tostring(wz[s]) or ""
    else ui.input = "" end
end

local function wzOres(wz)
    local l = {}
    for _, o in ipairs(ORES) do if wz.ores[o] then l[#l + 1] = o end end
    return l
end

local function wzLevels(wz)
    if not T.army then return {} end
    return T.army.levelsFor(wzOres(wz), nil, wz.y)
end

local function wzCreate(ui)
    local wz = ui.wz
    if #wzOres(wz) == 0 then ui.msg = "Pick an ore first"; return end
    if #wzLevels(wz) == 0 then ui.msg = "No level below station Y"; return end
    local a, err = send("army_new", { name = wz.name, station = { x = wz.x, y = wz.y, z = wz.z, f = wz.f },
        ores = wzOres(wz) })
    if not a then ui.msg = tostring(err); return end
    ui.army = { name = wz.name, tab = "map", lvl = 1, ox = 0, oy = 0, scr = 0 }
    ui.wz, ui.view, ui.msg = nil, "army", nil
    if not S.armies[wz.name] then ui.view, ui.msg = "armies", "Sent to the leader" end
end

local function wzSpec(ui)
    local wz = ui.wz
    local s = STEPN[wz.step]
    if s == "name" then
        return { prompt = "Army name (letters, digits):", text = true, max = 12, hint = "Enter = next",
            extra = { { "AUTO", colors.blue, function()
                local i = 1
                while S.armies["army" .. i] do i = i + 1 end
                ui.input = "army" .. i
            end } },
            ok = function(v)
                if v == "" then return "Type a name" end
                if S.armies[v] then return "Name taken" end
                wz.name = v
                wzGoto(ui, 2)
            end }
    end
    local lo, hi = -30000000, 30000000
    if s == "y" then lo, hi = -64, 320 end
    local label = ({ x = "Station X", y = "Station Y", z = "Station Z" })[s]
    return { prompt = label .. " (the station block):", lo = lo, hi = hi, hint = "range " .. lo .. ".." .. hi,
        ok = function(v)
            wz[s] = v
            wzGoto(ui, wz.step + 1)
        end }
end

local function wzBack(ui)
    local wz = ui.wz
    if not wz or wz.step <= 1 then ui.wz, ui.view, ui.msg = nil, "armies", nil; return end
    wzGoto(ui, wz.step - 1)
end

local function lvText(levels)
    local t = {}
    for _, lv in ipairs(levels) do t[#t + 1] = tostring(lv.y) end
    return #t > 0 and table.concat(t, " ") or "none"
end

local function renderWiz(ui)
    local wz = ui.wz
    if not wz then ui.view = "armies"; return T.VIEWS.armies(ui) end
    local s = STEPN[wz.step]
    local tag = wz.step .. "/" .. #STEPN
    if s == "name" or s == "x" or s == "y" or s == "z" then
        return renderEntry(ui, "New army", wzSpec(ui), tag)
    end
    header(ui, "New army", tag, false)
    if s == "face" then
        put(ui, 1, 2, trunc("Station facing (N E S W):", ui.w), colors.lightGray)
        put(ui, 1, 3, trunc(wz.x .. " " .. wz.y .. " " .. wz.z, ui.w), colors.white)
        if ui.msg then put(ui, 1, 4, trunc(ui.msg, ui.w), colors.red) end
        local defs = {}
        for _, f in ipairs(FACES) do
            defs[#defs + 1] = { f[1], wz.f == f[2] and colors.green or colors.blue, function()
                wz.f = f[2]; wzGoto(ui, 6)
            end }
        end
        defs[#defs + 1] = { "BACK", colors.red, function() wzBack(ui) end }
        buttonGrid(ui, defs, 5, 3)
    elseif s == "ores" then
        local lv = wzLevels(wz)
        put(ui, 1, 2, trunc("Ores to mine (1-9):", ui.w), colors.lightGray)
        put(ui, 1, 3, trunc("Levels: " .. lvText(lv), ui.w), colors.white)
        if ui.msg then put(ui, 1, 4, trunc(ui.msg, ui.w), colors.red) end
        local defs = {}
        for i, o in ipairs(ORES) do
            defs[#defs + 1] = { (ui.w >= 30 and (i .. " ") or "") .. o, wz.ores[o] and colors.green or colors.blue,
                function() wz.ores[o] = (not wz.ores[o]) or nil; wz.tabbed = false end }
        end
        defs[#defs + 1] = { "NEXT", colors.green, function()
            if #wzOres(wz) == 0 then ui.msg = "Pick an ore first" elseif #lv == 0 then ui.msg = "No level below Y"
            else wzGoto(ui, 7) end
        end }
        defs[#defs + 1] = { "BACK", colors.red, function() wzBack(ui) end }
        buttonGrid(ui, defs, 3, 3)
    else
        local lv = wzLevels(wz)
        local L = {
            "Name: " .. wz.name,
            "Station: " .. wz.x .. " " .. wz.y .. " " .. wz.z,
            "Facing: " .. FACE_NAME[wz.f or 0],
            "Ores: " .. table.concat(wzOres(wz), ","),
            "Levels: " .. lvText(lv),
        }
        if ui.msg then L[#L + 1] = ui.msg end
        local top = buttonGrid(ui, {
            { "CREATE", colors.green, function() wzCreate(ui) end },
            { "BACK", colors.red, function() wzBack(ui) end },
        }, 2, #L)
        for i, l in ipairs(L) do
            if 1 + i >= top then break end
            put(ui, 1, 1 + i, trunc(l, ui.w), (l == ui.msg) and colors.red or colors.white)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Army list and turtle-card JOIN picker
-- ---------------------------------------------------------------------------
local function armyLabel(a)
    local nm, nb = 0, 0
    for _ in pairs(a.members or {}) do nm = nm + 1 end
    nb = a.stats and a.stats.branchesDone or 0
    return a.name .. " " .. nm .. "trt " .. #(a.levels or {}) .. "lv " .. nb .. "done" .. (a.paused and " PAUSED" or "")
end

local function renderArmies(ui)
    header(ui, "Armies", nil, false)
    local nm = names()
    local top = buttonGrid(ui, {
        { "NEW", colors.green, function() ui.wz = { step = 1, ores = {}, name = "" }; wzGoto(ui, 1); ui.view = "armywiz" end },
        { "BACK", colors.gray, function() ui.view = "net" end },
    }, 2, #nm)
    if #nm == 0 then put(ui, 1, 2, trunc("No army yet. NEW makes one.", ui.w), colors.lightGray) end
    local room = top - 2
    for i, n in ipairs(nm) do
        if i > room then
            put(ui, 1, 1 + i, "+" .. (#nm - room + 1) .. " more", colors.gray)
            break
        end
        local a = S.armies[n]
        button(ui, 1, 1 + i, ui.w, armyLabel(a), colors.blue, function()
            ui.army = { name = n, tab = "map", lvl = 1, ox = 0, oy = 0, scr = 0 }
            ui.view, ui.msg = "army", nil
        end)
    end
end

local function renderJoin(ui)
    local r = U.currentRec(ui)
    if not r then ui.view = "list"; return U.renderList(ui) end
    header(ui, "Join army #" .. r.id, nil, true)
    local nm = names()
    if #nm == 0 then
        put(ui, 1, 2, trunc("No army yet.", ui.w), colors.orange)
        put(ui, 1, 3, trunc("NET > ARMY > NEW first.", ui.w), colors.lightGray)
    else
        put(ui, 1, 2, trunc("Turtle must sit at the station.", ui.w), colors.lightGray)
    end
    for i, n in ipairs(nm) do
        if 2 + i >= ui.h then break end
        button(ui, 1, 2 + i, ui.w, n, colors.blue, function() U.doCmd(ui, "ARMY_JOIN", { name = n }) end)
    end
    button(ui, 2, ui.h, math.max(4, math.min(12, ui.w - 2)), "BACK", colors.gray, function() ui.view = "detail" end)
end

-- ---------------------------------------------------------------------------
-- Army page: MAP
-- ---------------------------------------------------------------------------
local function levelOf(army, st)
    local n = #army.levels
    if n == 0 then return nil end
    if not st.lvl or st.lvl < 1 then st.lvl = 1 end
    if st.lvl > n then st.lvl = n end
    return army.levels[st.lvl], st.lvl
end

local function paint(m, f1, f2, r1, r2, ch)
    local z = m.z
    local c1, c2 = fl((r1 - m.r0) / z) + 1, fl((r2 - m.r0) / z) + 1
    local w1, w2 = fl((f1 - m.f0) / z) + 1, fl((f2 - m.f0) / z) + 1
    if c2 < 1 or c1 > m.cols or w2 < 1 or w1 > m.rows then return end
    c1, w1 = math.max(c1, 1), math.max(w1, 1)
    c2, w2 = math.min(c2, m.cols), math.min(w2, m.rows)
    local p = PRIO[ch]
    for rr = w1, w2 do
        local row = m.buf[rr]
        for cc = c1, c2 do
            if (PRIO[row[cc]] or 0) < p then row[cc] = ch end
        end
    end
end

local function toFrame(station, pos)
    local F, R = DVEC[station.f % 4], DVEC[(station.f + 1) % 4]
    local dx, dz = pos.x - station.x, pos.z - station.z
    return dx * F[1] + dz * F[2], dx * R[1] + dz * R[2]
end

local function renderMap(ui, army, st, top, bot)
    local A = T.army
    local lv, idx = levelOf(army, st)
    if not lv then put(ui, 1, top, "No levels. Add one in SET.", colors.orange); return end
    local rows, cols = bot - top, ui.w            -- row `top` holds the level line
    local g = army.geom
    local W = 2 * g.bl + g.sp
    local nb = A.branchesPerCorridor(g)
    local cs, cmin, cmax = { [0] = true }, 0, 0
    for key in pairs(army.branches) do
        local y, c = A.parseKey(key)
        if y == lv.y then
            cs[c] = true
            if c < cmin then cmin = c end
            if c > cmax then cmax = c end
        end
    end
    local rmin, rmax, fmax = cmin * W - g.bl, cmax * W + g.bl, 1 + g.ml
    local z = st.z
    if not z then
        z = ZOOMS[#ZOOMS]
        for _, zz in ipairs(ZOOMS) do
            if (rmax - rmin + 1) / zz <= cols and (fmax + 1) / zz <= rows then z = zz; break end
        end
    end
    local m = { z = z, cols = cols, rows = rows, buf = {}, f0 = (st.oy or 0) * z,
        r0 = fl((rmin + rmax) / 2) - fl(cols * z / 2) + (st.ox or 0) * z }
    for i = 1, rows do
        local row = {}
        for j = 1, cols do row[j] = " " end
        m.buf[i] = row
    end
    -- spine, mains, branches (free first, claimed / done from the record)
    paint(m, 2, 2, rmin, rmax, "-")
    for c in pairs(cs) do
        paint(m, 2, fmax, c * W, c * W, "|")
        for b = 0, nb - 1 do
            local f = A.branchF(g, b)
            for _, side in ipairs({ "R", "L" }) do
                local br = army.branches[A.branchKey(lv.y, c, b, side)]
                local r1, r2 = c * W + 1, c * W + g.bl
                if side == "L" then r1, r2 = c * W - g.bl, c * W - 1 end
                if not br then paint(m, f, f, r1, r2, ".")
                else paint(m, f, f, r1, r2, br.state == "done" and "#" or (br.state == "claimed" and "+" or ".")) end
            end
        end
    end
    local sh = army.shafts and army.shafts[2] and army.shafts[2].done
    paint(m, 0, 1, 0, 0, "S")
    if sh then paint(m, 1, 1, 1, 1, "S") end
    -- turtles
    for tid in pairs(army.members or {}) do
        local rec = S.turtles[tid]
        local pos = rec and rec.st and rec.st.pos
        if type(pos) == "table" and tonumber(pos.x) and tonumber(pos.z) then
            local f, r = toFrame(army.station, pos)
            local inShaft = f >= 0 and f <= 1 and r >= 0 and r <= 1
            if inShaft or math.abs((tonumber(pos.y) or 0) - lv.y) <= 3 then
                local fc = tonumber(rec.st.facing)
                local ch = fc and ARROW[(fc - army.station.f) % 4] or "?"
                if ch == "?" then ch = ">" end
                paint(m, f, f, r, r, ch)
            end
        end
    end
    local info = "Y" .. lv.y .. " " .. idx .. "/" .. #army.levels .. " x" .. z .. " "
        .. (#lv.focus > 0 and table.concat(lv.focus, ",") or "any")
    put(ui, 1, top, trunc(info, ui.w), colors.white)
    for i = 1, rows do
        local row, j = m.buf[i], 1
        while j <= cols do
            local ch, k = row[j], j
            while k < cols and CCOL[row[k + 1]] == CCOL[ch] and (row[k + 1] == " ") == (ch == " ") do k = k + 1 end
            if ch ~= " " then
                put(ui, j, top + i, table.concat(row, "", j, k), CCOL[ch] or colors.white)
            end
            j = k + 1
        end
    end
end

-- ---------------------------------------------------------------------------
-- TRAFFIC and STATS lines
-- ---------------------------------------------------------------------------
local function trafficLines(army)
    local L = {}
    local function add(t, fg) L[#L + 1] = { t, fg or colors.white } end
    local now = T.now()
    for k = 1, 2 do
        local sh = army.shafts and army.shafts[k]
        if sh then
            add("Shaft " .. k .. ": " .. (sh.done and "ready" or (sh.digger and ("digging #" .. sh.digger) or "not dug")),
                sh.done and colors.white or colors.lightGray)
        end
    end
    local keys = sortedKeys(army.segs or {})
    if #keys == 0 then add("No lane in use", colors.lightGray) end
    for _, key in ipairs(keys) do
        local s = army.segs[key]
        add(key .. " " .. tostring(s.dir) .. " " .. ids(s.holders), colors.lime)
    end
    local q = {}
    for _, tid in ipairs(army.queue or {}) do q[#q + 1] = "#" .. tid end
    add("Station queue: " .. (#q > 0 and table.concat(q, " ") or "empty"), #q > 0 and colors.yellow or colors.lightGray)
    for _, sl in ipairs(army.slots or {}) do
        local d = (sl.at or 0) - now
        add("Slot #" .. tostring(sl.tid) .. " shaft " .. tostring(sl.shaft) .. " " .. tostring(sl.dir) .. " "
            .. (d > 0 and ("in " .. span(d)) or "now") .. " for " .. span(sl.len or 0), colors.lightBlue)
    end
    local w = army.wait or {}
    add("Wait avg " .. span(w.avgMs or 0) .. " (" .. tostring(w.n or 0) .. ")", colors.lightGray)
    return L
end

local function statsLines(army)
    local L = {}
    local function add(t, fg) L[#L + 1] = { t, fg or colors.white } end
    local now = T.now()
    local s = army.stats or {}
    local hrs = math.max((now - (s.startedAt or now)) / 3600000, 1 / 60)
    add("Running " .. span(now - (s.startedAt or now)) .. (army.paused and "  PAUSED" or ""),
        army.paused and colors.yellow or colors.white)
    add("Ores per hour:", colors.lightGray)
    local fam = sortedKeys(s.ores or {})
    if #fam == 0 then add(" none yet", colors.gray) end
    for _, f in ipairs(fam) do
        add(string.format(" %s %.1f (%d)", f, s.ores[f] / hrs, s.ores[f]))
    end
    local claimed, known = 0, 0
    for _, b in pairs(army.branches or {}) do
        known = known + 1
        if b.state == "claimed" then claimed = claimed + 1 end
    end
    add("Branches done " .. tostring(s.branchesDone or 0) .. "  claimed " .. claimed .. "  known " .. known)
    local active, away, help, quiet = 0, 0, 0, 0
    for tid in pairs(army.members or {}) do
        local r = S.turtles[tid]
        if not r then quiet = quiet + 1
        elseif r.st and r.st.phase == "NEEDS_HELP" then help = help + 1
        elseif r.alert == "SILENT" or r.alert == "OVERDUE" then quiet = quiet + 1
        elseif T.isAway and T.isAway(r, now) then away = away + 1
        else active = active + 1 end
    end
    add("Turtles active " .. active .. "  away " .. away .. "  help " .. help .. "  silent " .. quiet,
        (help + quiet) > 0 and colors.orange or colors.white)
    add("Fuel used " .. tostring(s.fuelUsed or 0))
    add("Extra digs " .. (function() local n = 0; for _ in pairs(army.extra or {}) do n = n + 1 end; return n end)(),
        colors.lightGray)
    return L
end

local function drawLines(ui, L, top, bot, st)
    local room = bot - top + 1
    local maxScr = math.max(0, #L - room)
    if (st.scr or 0) > maxScr then st.scr = maxScr end
    if (st.scr or 0) < 0 then st.scr = 0 end
    for i = 1, room do
        local l = L[st.scr + i]
        if not l then break end
        put(ui, 1, top + i - 1, trunc(l[1], ui.w), l[2])
    end
end

-- ---------------------------------------------------------------------------
-- SETTINGS and RELEASE
-- ---------------------------------------------------------------------------
local function setKey(ui, army, key, value)
    local a, err = send("army_set", { name = army.name, key = key, value = value })
    ui.msg = a and nil or tostring(err)
end

local function holdings(army, tid)
    local keys, nseg = {}, 0
    for key, b in pairs(army.branches or {}) do
        if b.state == "claimed" and b.tid == tid then keys[#keys + 1] = key end
    end
    for _, s in pairs(army.segs or {}) do if s.holders and s.holders[tid] then nseg = nseg + 1 end end
    return keys, nseg
end

local function silentHolders(army)
    local out, seen = {}, {}
    for _, b in pairs(army.branches or {}) do
        if b.state == "claimed" and b.tid then seen[b.tid] = true end
    end
    for _, s in pairs(army.segs or {}) do for tid in pairs(s.holders or {}) do seen[tid] = true end end
    for tid in pairs(seen) do if silent(tid) then out[#out + 1] = tid end end
    table.sort(out)
    return out
end

local function renderSet(ui, army, st, top)
    local lv = levelOf(army, st)
    local s = army.settings or {}
    local L = {}
    local ys = {}
    for _, l in ipairs(army.levels) do ys[#ys + 1] = (l == lv and "[" or "") .. l.y .. (l == lv and "]" or "") end
    L[#L + 1] = "Levels " .. table.concat(ys, " ")
    L[#L + 1] = "Focus " .. tostring(s.FOCUS or "all") .. "  GPS " .. ((s.MOBILE_GPS ~= false) and "on" or "off")
    L[#L + 1] = "Paused " .. (army.paused and "yes" or "no") .. "  Return " .. (s.RETURN and "yes" or "no")
    if ui.msg then L[#L + 1] = ui.msg end
    local function sel(d) return function() st.lvl = (st.lvl or 1) + d; levelOf(army, st) end end
    local defs = {
        { "LV <", colors.blue, sel(-1) },
        { "LV >", colors.blue, sel(1) },
        { "ADD LV", colors.green, function()
            st.num = { prompt = "New level Y (below " .. army.station.y .. "):", lo = -64, hi = army.station.y - 1,
                ok = function(v)
                    local a, err = send("army_set", { name = army.name, key = "level_add", value = v })
                    if a then ui.view, ui.input = "army", "" else return tostring(err) end
                end }
            ui.input, st.tabbed, ui.msg, ui.view = "", false, nil, "armynum"
        end },
        { "DEL LV", colors.red, function()
            if #army.levels <= 1 then ui.msg = "Keep one level"
            elseif lv then setKey(ui, army, "level_remove", lv.y) end
        end },
        { "FOCUS", colors.blue, function()
            local list, c, nxt = T.FOCUS_LIST or { "all" }, s.FOCUS or "all", 1
            for i, f in ipairs(list) do if f == c then nxt = i % #list + 1 end end
            setKey(ui, army, "FOCUS", list[nxt])
        end },
        { "GPS", colors.blue, function() setKey(ui, army, "MOBILE_GPS", s.MOBILE_GPS == false) end },
        { army.paused and "RESUME" or "PAUSE", army.paused and colors.green or colors.yellow, function()
            setKey(ui, army, "paused", not army.paused)
        end, army.paused and colors.white or colors.black },
        { s.RETURN and "UNRETURN" or "RETURN", colors.orange, function() setKey(ui, army, "RETURN", not s.RETURN) end },
        { "RELEASE", colors.red, function() ui.view, ui.msg = "armyrel", nil end },
        { "BACK", colors.gray, function() ui.view, ui.msg = "armies", nil end },
    }
    local gtop = buttonGrid(ui, defs, 3, #L + (top - 2))
    for i, l in ipairs(L) do
        if top + i - 1 >= gtop then break end
        put(ui, 1, top + i - 1, trunc(l, ui.w), (l == ui.msg) and colors.red or colors.white)
    end
end

local function renderRel(ui)
    local army, st = cur(ui)
    if not army then ui.view = "armies"; return T.VIEWS.armies(ui) end
    header(ui, "Release", army.name, false)
    local list = silentHolders(army)
    if #list == 0 then
        put(ui, 1, 2, trunc("No silent turtle holds a", ui.w), colors.lightGray)
        put(ui, 1, 3, trunc("claim or lane.", ui.w), colors.lightGray)
    else
        put(ui, 1, 2, trunc("Silent turtles holding work:", ui.w), colors.orange)
    end
    for i, tid in ipairs(list) do
        if 2 + i >= ui.h then break end
        local keys, nseg = holdings(army, tid)
        local r = S.turtles[tid]
        local lbl = "#" .. tid .. " " .. (keys[1] or "-") .. (nseg > 0 and (" +" .. nseg .. "seg") or "")
            .. (r and (" " .. span(T.now() - (r.lastSeen or 0))) or "")
        button(ui, 1, 2 + i, ui.w, lbl, colors.red, function() st.rel = tid; ui.view = "armyrelok" end)
    end
    button(ui, 2, ui.h, math.max(4, math.min(12, ui.w - 2)), "BACK", colors.gray, function() ui.view = "army" end)
end

local function renderRelOk(ui)
    local army, st = cur(ui)
    if not army or not st.rel then ui.view = "army"; return T.VIEWS.army(ui) end
    header(ui, "Release #" .. st.rel .. "?", nil, false)
    local keys, nseg = holdings(army, st.rel)
    local text = "Free " .. (keys[1] or "no branch") .. " and " .. nseg .. " lane segment(s) held by #" .. st.rel
        .. "? It is probably frozen in place. If it is still alive it may dig the same branch twice."
    for i, l in ipairs(T.wrap(text, ui.w)) do
        if 1 + i > ui.h - 2 then break end
        put(ui, 1, 1 + i, l, colors.white)
    end
    local half = math.max(1, fl((ui.w - 3) / 2))
    button(ui, 2, ui.h, half, "YES FREE", colors.red, function()
        local a, err = send("army_release", { name = army.name, tid = st.rel })
        ui.msg = a and ("released #" .. st.rel) or tostring(err)
        st.rel, ui.view = nil, "armyrel"
    end)
    button(ui, 3 + half, ui.h, half, "NO", colors.gray, function() ui.view = "armyrel" end)
end

-- ---------------------------------------------------------------------------
-- Army page
-- ---------------------------------------------------------------------------
local function renderArmy(ui)
    local army, st = cur(ui)
    if not army then ui.view = "armies"; return T.VIEWS.armies(ui) end
    header(ui, "ARMY " .. army.name, army.paused and "PAUSED" or nil, false)
    st.tab = st.tab or "map"
    local bw = math.max(1, fl((ui.w - 3) / 4))
    for i, t in ipairs(TABS) do
        button(ui, 1 + (i - 1) * (bw + 1), 2, bw, bw >= 9 and t[3] or (bw >= 4 and t[2] or t[2]:sub(1, bw)),
            st.tab == t[1] and colors.green or colors.blue, function() st.tab = t[1]; st.scr = 0; ui.msg = nil end)
    end
    local function foot(defs)
        local n = #defs
        local w1 = math.max(1, fl((ui.w - (n - 1)) / n))
        for i, d in ipairs(defs) do button(ui, 1 + (i - 1) * (w1 + 1), ui.h, w1, d[1], d[2] or colors.gray, d[3]) end
    end
    local back = { "BACK", colors.gray, function() ui.view, ui.msg = "armies", nil end }
    if st.tab == "map" then
        local _, n = levelOf(army, st)
        renderMap(ui, army, st, 3, ui.h - 2)
        local leg = ui.w >= 40 and "# done  + claimed  . free  S shaft  ^>v< turtle" or "#done +claim .free S ^>v<"
        put(ui, 1, ui.h - 1, trunc(leg, ui.w), colors.gray)
        foot({
            { "LV-", colors.blue, function() st.lvl = (st.lvl or 1) - 1; levelOf(army, st) end },
            { "LV+", colors.blue, function() st.lvl = (st.lvl or 1) + 1; levelOf(army, st) end },
            { "Z+", colors.blue, function() st.z = math.max(1, (st.z or 4) - 1); st.ox, st.oy = 0, 0 end },
            { "Z-", colors.blue, function() st.z = (st.z or 4) + 1; st.ox, st.oy = 0, 0 end },
            { "AUTO", colors.blue, function() st.z, st.ox, st.oy = nil, 0, 0 end },
            back,
        })
    elseif st.tab == "traf" or st.tab == "stats" then
        drawLines(ui, st.tab == "traf" and trafficLines(army) or statsLines(army), 3, ui.h - 1, st)
        foot({ { "UP", colors.blue, function() st.scr = math.max(0, (st.scr or 0) - 3) end },
            { "DOWN", colors.blue, function() st.scr = (st.scr or 0) + 3 end }, back })
    else
        renderSet(ui, army, st, 3)
    end
end

local function renderNum(ui)
    local army, st = cur(ui)
    if not army or not st.num then ui.view = "army"; return T.VIEWS.army(ui) end
    renderEntry(ui, "Add level", st.num, nil)
end

-- ---------------------------------------------------------------------------
-- Keyboard
-- ---------------------------------------------------------------------------
local function entryKey(ui, spec, e, v)
    local ts = tabState(ui)
    if e == "char" then
        entryChar(ui, spec, v)
        return true
    end
    if e ~= "key" then return false end
    if v == keys.backspace then
        if (ui.input or "") ~= "" then ui.input = ui.input:sub(1, -2); ui.msg = nil else T.back(ui) end
        return true
    elseif v == keys.enter or v == keys.numPadEnter then
        if ts.tabbed then return false end
        entryOk(ui, spec)
        return true
    elseif v == keys.tab or v == keys.down or v == keys.up or v == keys.left or v == keys.right then
        ts.tabbed = true
    end
    return false
end

local function wizKey(ui, e, v)
    local wz = ui.wz
    if not wz then return false end
    local s = STEPN[wz.step]
    if s == "name" or s == "x" or s == "y" or s == "z" then return entryKey(ui, wzSpec(ui), e, v) end
    if e == "char" then
        local c = v:upper()
        if s == "face" then
            for _, f in ipairs(FACES) do if f[1] == c then wz.f = f[2]; wzGoto(ui, 6); return true end end
        elseif s == "ores" and v:match("^[1-9]$") and ORES[tonumber(v)] then
            local o = ORES[tonumber(v)]
            wz.ores[o] = (not wz.ores[o]) or nil
            wz.tabbed = false
            return true
        elseif s == "go" and (c == "Y") then wzCreate(ui); return true end
        return false
    end
    if e ~= "key" then return false end
    if v == keys.backspace then wzBack(ui); return true end
    if v == keys.tab or v == keys.down or v == keys.up or v == keys.left or v == keys.right then
        wz.tabbed = true
        return false
    end
    if (v == keys.enter or v == keys.numPadEnter) and not wz.tabbed then
        if s == "ores" then
            if #wzOres(wz) == 0 then ui.msg = "Pick an ore first"
            elseif #wzLevels(wz) == 0 then ui.msg = "No level below Y"
            else wzGoto(ui, 7) end
        elseif s == "go" then wzCreate(ui)
        elseif s == "face" and wz.f then wzGoto(ui, 6) end
        return true
    end
    return false
end

local function armyKey(ui, e, v)
    local army, st = cur(ui)
    if not army then return false end
    local tab = st.tab or "map"
    local function lvl(d) st.lvl = (st.lvl or 1) + d; levelOf(army, st) end
    if e == "char" then
        for i, t in ipairs(TABS) do
            if v == tostring(i) then st.tab, st.scr = t[1], 0; return true end
        end
        if tab == "map" then
            if v == "[" or v == "," then lvl(-1) elseif v == "]" or v == "." then lvl(1)
            elseif v == "+" or v == "=" then st.z = math.max(1, (st.z or 4) - 1); st.ox, st.oy = 0, 0
            elseif v == "-" then st.z = (st.z or 4) + 1; st.ox, st.oy = 0, 0
            elseif v == "0" then st.z, st.ox, st.oy = nil, 0, 0
            else return false end
            return true
        end
        return false
    end
    if e ~= "key" then return false end
    if tab == "map" then
        if v == keys.up then st.oy = (st.oy or 0) - 1
        elseif v == keys.down then st.oy = (st.oy or 0) + 1
        elseif v == keys.left then st.ox = (st.ox or 0) - 1
        elseif v == keys.right then st.ox = (st.ox or 0) + 1
        elseif v == keys.pageUp then lvl(-1)
        elseif v == keys.pageDown then lvl(1)
        else return false end
        return true
    elseif tab == "traf" or tab == "stats" then
        if v == keys.up then st.scr = math.max(0, (st.scr or 0) - 1)
        elseif v == keys.down then st.scr = (st.scr or 0) + 1
        elseif v == keys.pageUp then st.scr = math.max(0, (st.scr or 0) - 5)
        elseif v == keys.pageDown then st.scr = (st.scr or 0) + 5
        else return false end
        return true
    end
    return false
end

local function numKey(ui, e, v)
    local army, st = cur(ui)
    if not army or not st.num then return false end
    return entryKey(ui, st.num, e, v)
end

T.VIEWKEY = T.VIEWKEY or {}
T.VIEWKEY.armywiz, T.VIEWKEY.army, T.VIEWKEY.armynum = wizKey, armyKey, numKey
T.BACK = T.BACK or {}
T.BACK.armies, T.BACK.army, T.BACK.armynum = "net", "armies", "army"
T.BACK.armyrel, T.BACK.armyrelok, T.BACK.armywiz = "army", "armyrel", wzBack
T.BACK.armyjoin = "detail"

T.VIEWS.armies, T.VIEWS.army, T.VIEWS.armywiz, T.VIEWS.armynum = renderArmies, renderArmy, renderWiz, renderNum
T.VIEWS.armyrel, T.VIEWS.armyrelok, T.VIEWS.armyjoin = renderRel, renderRelOk, renderJoin

return T
