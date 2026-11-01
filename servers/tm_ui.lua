-- Version: 1.1.0
-- TurtleMiner server UI, part 1: drawing helpers, the turtle list and the turtle card, the
-- render dispatch, keyboard / mouse / touch input and the UI loop. Any number of displays
-- (monitors + the PC's own terminal, or a pocket). Keyboard first (docs/COMMS.md): arrow keys
-- / Tab move a focus marker, Enter activates, Backspace goes back; works on basic computers
-- and basic monitors (no colour, no mouse, no touch). A monitor without touch follows the
-- terminal: what you do on the keyboard shows on the monitor. More screens: tm_views.lua.
local T = ...
local S = T.S
local now, trunc, pad, lpad = T.now, T.trunc, T.pad, T.lpad
local labelOf, isAway, awayText = T.labelOf, T.isAway, T.awayText
local PHASE_SHORT = {
    BOOT = "BOOT", RECOVER = "RECOVR", TO_WORK = "TOWORK", MINING = "MINING", VEIN = "VEIN",
    RETURNING = "RETURN", UNLOADING = "UNLOAD", REFUELING = "REFUEL", IDLE = "IDLE",
    PAUSED = "PAUSED", NEEDS_HELP = "HELP!", ERROR = "ERROR", DONE = "DONE", SILENT = "SILENT",
    AWAY = "AWAY", OVERDUE = "LATE!",
}

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------
local function ago(ms)
    if not ms or ms <= 0 then return "never" end
    local s = math.floor((now() - ms) / 1000)
    if s < 0 then s = 0 end
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    return math.floor(s / 3600) .. "h"
end

local function compact(n)
    n = math.floor(n)
    if n >= 100000 then return math.floor(n / 1000) .. "k" end
    if n >= 10000 then return math.floor(n / 100) / 10 .. "k" end
    return tostring(n)
end

-- returns text, isLow
local function fuelStr(st, withNeed)
    local f = st.fuel
    if f == nil then return "-", false end
    if type(f) ~= "number" then return "unl", false end
    local need = tonumber(st.fuelNeeded)
    local low = need ~= nil and f < need
    local s = compact(f)
    if withNeed and need then s = s .. "/" .. compact(need) end
    return s, low
end

local function posStr(p)
    if type(p) ~= "table" then return "-" end
    return tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z)
end

local function distHome(st)
    local p, h = st.pos, st.home
    if type(p) ~= "table" or type(h) ~= "table" then return nil end
    local ok, d = pcall(function() return math.abs(p.x - h.x) + math.abs(p.y - h.y) + math.abs(p.z - h.z) end)
    return ok and math.floor(d) or nil
end

local function phaseColor(ph)
    if ph == "MINING" or ph == "VEIN" then return colors.lime end
    if ph == "TO_WORK" or ph == "RETURNING" or ph == "UNLOADING" or ph == "REFUELING" then return colors.lightBlue end
    if ph == "PAUSED" or ph == "BOOT" or ph == "RECOVER" then return colors.yellow end
    if ph == "NEEDS_HELP" then return colors.orange end
    if ph == "ERROR" then return colors.red end
    if ph == "SILENT" or ph == "AWAY" then return colors.gray end
    if ph == "OVERDUE" then return colors.red end
    return colors.white
end

local function shownPhase(r)
    if r.alert == "SILENT" or r.alert == "OVERDUE" then return r.alert end
    if isAway(r, now()) then return "AWAY" end
    return r.st.phase or "?"
end

-- Reason line: while away and silent, when it is expected back.
local function reasonOf(r)
    if r.away and (isAway(r, now()) or r.alert == "OVERDUE") then
        return awayText(r) .. (r.alert == "OVERDUE" and " - OVERDUE" or "")
    end
    return r.st.reason
end
T.shownPhase, T.reasonOf = shownPhase, reasonOf

local function cmdLine(r)
    local c = r.cmd
    if not c then return nil end
    if c.state == "pending" then
        return c.name .. ": waiting (" .. tostring(c.tries or 1) .. ")", colors.yellow
    elseif c.state == "queued" then
        return c.name .. ": queued " .. ago(c.at), colors.yellow
    elseif c.state == "ok" then
        return c.name .. ": ok " .. ago(c.at), colors.lime
    end
    return c.name .. ": FAILED " .. tostring(c.err or ""), colors.red
end

local function sortedTurtles()
    local arr = {}
    for _, r in pairs(S.turtles) do arr[#arr + 1] = r end
    table.sort(arr, function(a, b)
        local aa, ba = a.alert and 0 or 1, b.alert and 0 or 1
        if aa ~= ba then return aa < ba end
        local la, lb = labelOf(a):lower(), labelOf(b):lower()
        if la ~= lb then return la < lb end
        return a.id < b.id
    end)
    return arr
end

-- ---------------------------------------------------------------------------
-- UI: one responsive renderer, any number of displays (monitor + terminal)
-- ---------------------------------------------------------------------------
function T.newUI(dev, side)
    local ui = { dev = dev, side = side, view = "list", page = 1, sel = nil, buttons = {},
        input = "", msg = nil, text = nil, w = 1, h = 1 }
    ui.color = dev.isColor and dev.isColor() or false
    return ui
end

local function mapColor(ui, c, isBg)
    if ui.color then return c end
    if isBg then return (c == colors.black) and colors.black or colors.gray end
    return (c == colors.gray or c == colors.lightGray) and c or colors.white
end

local function put(ui, x, y, text, fg, bg)
    if y < 1 or y > ui.h or x > ui.w then return end
    text = tostring(text)
    if x < 1 then text = text:sub(2 - x); x = 1 end
    if #text > ui.w - x + 1 then text = text:sub(1, ui.w - x + 1) end
    if #text == 0 then return end
    local d = ui.out
    d.setTextColor(mapColor(ui, fg or colors.white, false))
    d.setBackgroundColor(mapColor(ui, bg or colors.black, true))
    d.setCursorPos(x, y)
    d.write(text)
end

local function fillLine(ui, y, bg)
    put(ui, 1, y, string.rep(" ", ui.w), colors.white, bg)
end

local function button(ui, x, y, w, label, bg, fn, fg)
    if w < 1 or y < 1 or y > ui.h then return end
    local t = trunc(label, w)
    local left = math.floor((w - #t) / 2)
    put(ui, x, y, string.rep(" ", left) .. t .. string.rep(" ", w - left - #t), fg or colors.white, bg)
    ui.buttons[#ui.buttons + 1] = { x1 = x, y1 = y, x2 = x + w - 1, y2 = y, fn = fn, key = label }
end

local function zone(ui, x1, y1, x2, y2, fn, key)
    ui.buttons[#ui.buttons + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn, key = key or ("@" .. y1) }
end

local function header(ui, title, right, backable)
    fillLine(ui, 1, colors.blue)
    local x = 1
    if backable then
        button(ui, 1, 1, 3, "<", colors.gray, function() ui.view = (ui.view == "detail") and "list" or "detail" end)
        x = 5
    end
    right = right or ""
    local room = ui.w - x + 1 - (#right > 0 and (#right + 1) or 0)
    if room < 1 then right = ""; room = ui.w - x + 1 end
    put(ui, x, 1, trunc(title, room), colors.white, colors.blue)
    if #right > 0 then put(ui, ui.w - #right + 1, 1, right, colors.yellow, colors.blue) end
end

local function gridCols(ui, maxCols)
    return math.max(1, math.min(maxCols, math.floor((ui.w + 1) / 12)))
end

-- Lay buttons out in a grid at the bottom. defs = {{label, bg, fn, fg}, ...}.
-- reserve = rows wanted above the grid (besides the header). Returns top row used.
local function buttonGrid(ui, defs, maxCols, reserve)
    local bottom = ui.h
    local cols = gridCols(ui, maxCols)
    if ui.h > 1 then cols = math.min(#defs, math.max(cols, math.ceil(#defs / (ui.h - 1)))) end
    local rows = math.ceil(#defs / cols)
    local bw = math.max(1, math.floor((ui.w - (cols + 1)) / cols))
    if ui.w < cols + 2 then bw = math.max(1, math.floor(ui.w / cols)) end
    local gap = (bottom - 1 - (reserve or 0) >= rows * 2 - 1) and 1 or 0
    local top = bottom - (rows * (1 + gap) - gap) + 1
    for i, d in ipairs(defs) do
        local c = (i - 1) % cols
        local rr = math.floor((i - 1) / cols)
        local x = 2 + c * (bw + 1)
        if ui.w < cols + 2 then x = 1 + c * bw end
        button(ui, x, top + rr * (1 + gap), bw, d[1], d[2], d[3], d[4])
    end
    return top
end

local function currentRec(ui)
    return ui.sel and S.turtles[ui.sel] or nil
end

local function doCmd(ui, cmd, params)
    if ui.sel then T.issueCmd(ui.sel, cmd, params) end
    ui.view = "detail"
end

-- List view ---------------------------------------------------------------
local function drawRow(ui, r, y, rowsPer)
    local w, st = ui.w, r.st
    local bg = r.alert and colors.red or colors.black
    for k = 0, rowsPer - 1 do fillLine(ui, y + k, bg) end
    local ph = shownPhase(r)
    local phFg = r.alert and colors.yellow or phaseColor(ph)
    local function lowFg(low) return low and (r.alert and colors.yellow or colors.red) or colors.white end
    if w >= 40 then
        local wide = w >= 60
        local nw, pw, fw = wide and 16 or 13, wide and 11 or 7, wide and 12 or 6
        local fuel, low = fuelStr(st, wide)
        local d = distHome(st)
        local x = 1
        put(ui, x, y, pad(labelOf(r), nw), colors.white, bg); x = x + nw + 1
        put(ui, x, y, pad(wide and ph or (PHASE_SHORT[ph] or ph), pw), phFg, bg); x = x + pw + 1
        put(ui, x, y, pad(fuel, fw), lowFg(low), bg); x = x + fw + 1
        put(ui, x, y, pad(d and ("h" .. d) or "h-", 6), colors.white, bg); x = x + 7
        put(ui, x, y, pad(ago(r.lastSeen), 5), colors.lightGray, bg); x = x + 6
        if rowsPer == 1 and x <= w then
            put(ui, x, y, trunc(reasonOf(r) or "", w - x + 1), colors.lightGray, bg)
        end
    else
        local fuel, low = fuelStr(st, false)
        local pw, fw = 6, 5
        local nw = w - pw - fw - 2
        if nw < 3 then fw = 0; nw = w - pw - 1 end
        put(ui, 1, y, pad(labelOf(r), nw), colors.white, bg)
        put(ui, nw + 2, y, pad(PHASE_SHORT[ph] or ph, pw), phFg, bg)
        if fw > 0 then put(ui, w - fw + 1, y, lpad(fuel, fw), lowFg(low), bg) end
    end
    if rowsPer == 2 then
        local t, fg = reasonOf(r) or st.lastError, colors.lightGray
        if not t then t, fg = cmdLine(r) end
        if not t then t = "#" .. r.id .. " " .. posStr(st.pos) end
        put(ui, 3, y + 1, trunc(t, w - 2), r.alert and colors.white or (fg or colors.lightGray), bg)
    end
    zone(ui, 1, y, w, y + rowsPer - 1, function() ui.sel = r.id; ui.view = "detail" end, "#" .. r.id)
end

local function renderList(ui)
    local w, h = ui.w, ui.h
    local arr = sortedTurtles()
    local nAlert = 0
    for _, r in ipairs(arr) do if r.alert then nAlert = nAlert + 1 end end
    local title = S.mode == "server" and ("TMINER srv#" .. S.myId) or "TMINER pocket"
    header(ui, title, #arr .. (nAlert > 0 and (" " .. nAlert .. "!") or ""), false)
    local bodyTop, bodyBot = 2, h - 1
    local bodyH = bodyBot - bodyTop + 1
    if bodyH < 1 then return end
    local rowsPer = (w >= 30 and bodyH >= #arr * 2) and 2 or 1
    local perPage = math.max(1, math.floor(bodyH / rowsPer))
    local pages = math.max(1, math.ceil(#arr / perPage))
    if ui.page > pages then ui.page = pages end
    if ui.page < 1 then ui.page = 1 end
    if #arr == 0 then
        put(ui, 1, 2, trunc(S.mode == "pocket" and "Waiting for server..." or "No turtles heard yet", w), colors.lightGray)
    end
    for i = 1, perPage do
        local r = arr[(ui.page - 1) * perPage + i]
        if not r then break end
        drawRow(ui, r, bodyTop + (i - 1) * rowsPer, rowsPer)
    end
    -- footer
    fillLine(ui, h, colors.gray)
    local x = 1
    if pages > 1 then
        button(ui, 1, h, 3, "<", colors.blue, function() ui.page = math.max(1, ui.page - 1) end)
        button(ui, 5, h, 3, ">", colors.blue, function() ui.page = math.min(pages, ui.page + 1) end)
        x = 9
    end
    local info
    if S.mode == "pocket" then
        if S.fleetFrom and now() - S.fleetAt < 15000 then
            info = "srv#" .. S.fleetFrom .. " " .. ago(S.fleetAt)
        else
            info = "no server"
        end
    else
        info = (S.netOk and S.modemKind or "NO MODEM") .. (T.clusterText and (" " .. T.clusterText()) or "")
    end
    -- Mining network: missing network, join requests waiting, foreign/bad messages dropped.
    local joins = T.joinList and #T.joinList() or 0
    if not S.signer then info = "NO NETWORK " .. info end
    if joins > 0 then info = "JOIN? " .. info end
    if (S.bad or 0) > 0 then info = info .. " bad:" .. S.bad end
    if pages > 1 then info = ui.page .. "/" .. pages .. " " .. info end
    local logW = (w - x + 1 >= 10) and 5 or 0
    local netW = (w - x + 1 >= 16) and 5 or 0
    local used = (logW > 0 and logW + 1 or 0) + (netW > 0 and netW + 1 or 0)
    put(ui, x, h, trunc(info, w - x + 1 - used), colors.white, colors.gray)
    if netW > 0 then
        button(ui, w - logW - netW, h, netW, "NET", joins > 0 and colors.orange or colors.blue,
            function() ui.view = "net"; ui.msg = nil end)
    end
    if logW > 0 then button(ui, w - logW + 1, h, logW, "LOG", colors.blue, function() ui.view = "log" end) end
end

-- Detail view ---------------------------------------------------------------
local function detailLines(r, wide)
    local st, L = r.st, {}
    local function add(k, v, fg) L[#L + 1] = { k, tostring(v), fg } end
    local ph = shownPhase(r)
    add("Phase", ph .. (r.alert and r.alert ~= ph and (" " .. r.alert) or ""), phaseColor(ph))
    local why = reasonOf(r)
    add("Why", why or "-", why and colors.orange or nil)
    local need = tonumber(st.fuelNeeded)
    local fuelTxt, low = fuelStr(st, false)
    add("Fuel", fuelTxt .. (need and (" need " .. compact(need)) or ""), low and colors.red or nil)
    local d = distHome(st)
    add("Home", (d and (d .. " blk") or "-") .. (wide and type(st.home) == "table" and (" @" .. posStr(st.home)) or ""))
    add("Pos", posStr(st.pos) .. (st.facing and (" f" .. tostring(st.facing)) or ""))
    local j = st.job
    if type(j) == "table" then
        add("Job", "c" .. tostring(j.corridor) .. " b" .. tostring(j.branch) .. " " .. tostring(j.side or "")
            .. " s" .. tostring(j.step))
    else
        add("Job", "-")
    end
    local s = type(st.stats) == "table" and st.stats or {}
    add("Ores", tostring(s.ores or "-") .. (wide and ("  blocks " .. tostring(s.blocks or "-") .. "  trips "
        .. tostring(s.trips or "-")) or (" trips " .. tostring(s.trips or "-"))))
    add("Seen", ago(r.lastSeen) .. " ago", r.alert == "SILENT" and colors.red or nil)
    add("GPS", (st.gps == true and "yes" or (st.gps == false and "no" or "-")) .. "  v" .. tostring(st.version or "?"))
    local cfg = type(st.cfg) == "table" and st.cfg or {}
    add("Cfg", "Y " .. tostring(cfg.targetY or "-") .. " focus " .. tostring(cfg.focus or "-"))
    add("Error", st.lastError or "-", st.lastError and colors.red or nil)
    local ct, cfg2 = cmdLine(r)
    add("Cmd", ct or "-", cfg2)
    for _, e in ipairs(r.events) do
        add("Ev", ago(e.at) .. " " .. tostring(e.text),
            e.level == "error" and colors.red or (e.level == "warn" and colors.orange or colors.lightGray))
    end
    return L
end

-- Shared with tm_views.lua
T.ui = {
    put = put, fillLine = fillLine, button = button, zone = zone, header = header, gridCols = gridCols,
    buttonGrid = buttonGrid, currentRec = currentRec, doCmd = doCmd, renderList = renderList,
    detailLines = detailLines, posStr = posStr, ago = ago,
}
T.VIEWS = T.VIEWS or {}

-- Navigation state a monitor without touch copies from the terminal (keyboard) UI.
local NAV = { "view", "sel", "page", "setKey", "input", "msg", "text", "confirmCmd" }

function T.render(ui)
    local w, h = ui.dev.getSize()
    ui.w, ui.h = w, h
    if window and not ui.win then ui.win = window.create(ui.dev, 1, 1, w, h, false) end
    if ui.win then
        local ww, wh = ui.win.getSize()
        if ww ~= w or wh ~= h then ui.win.reposition(1, 1, w, h) end
        ui.win.setVisible(false)
        ui.out = ui.win
    else
        ui.out = ui.dev
    end
    ui.buttons = {}
    ui.out.setBackgroundColor(colors.black)
    ui.out.clear()
    local fn = T.VIEWS[ui.view]
    if fn and ui.view ~= "list" then fn(ui)
    else
        ui.view = "list"
        renderList(ui)
    end
    -- Keyboard focus marker (after the first arrow/tab key; basic computers have no mouse).
    if ui.focusKey then
        ui.focus = nil
        for i, b in ipairs(ui.buttons) do if b.key == ui.focusKey then ui.focus = i; break end end
    end
    if ui.focus then
        if ui.focus > #ui.buttons then ui.focus = #ui.buttons end
        local b = ui.buttons[ui.focus]
        if b then put(ui, b.x1, b.y1, ">", colors.yellow, colors.black) end
    end
    if ui.win then ui.win.setVisible(true) end
end

-- One step back (Backspace): the card from its sub-screens, the list from the card / log.
function T.back(ui)
    if ui.view == "list" then return false end
    if ui.view == "detail" or ui.view == "log" or ui.view == "net" then ui.view = "list"
    elseif ui.view == "netconfirm" or ui.view == "netcode" then ui.view = "net"
    else ui.view = "detail" end
    ui.msg = nil
    return true
end

-- Arrow keys / Tab move a focus over the clickable things, Enter activates it. Works on any
-- computer (no colour, mouse or touch needed). Returns true when the key was used.
function T.navKey(ui, key)
    if not keys then return false end
    -- Number entry: Enter is OK and Backspace deletes (typed digits; see T.keyInput).
    if ui.view == "num" and (key == keys.enter or key == keys.numPadEnter or key == keys.backspace) then return false end
    local n = #ui.buttons
    if key == keys.down or key == keys.right or key == keys.tab then
        if n == 0 then return true end
        ui.focus = ((ui.focus or 0) % n) + 1
    elseif key == keys.up or key == keys.left then
        if n == 0 then return true end
        ui.focus = (((ui.focus or 1) - 2) % n) + 1
    elseif (key == keys.enter or key == keys.numPadEnter) and ui.focus and ui.buttons[ui.focus] then
        local b = ui.buttons[ui.focus]
        ui.focus = 1
        b.fn()
    elseif key == keys.backspace and ui.view ~= "num" then
        if not T.back(ui) then return false end
        ui.focus = 1
    else
        return false
    end
    T.render(ui)
    return true
end

function T.click(ui, x, y)
    for i = #ui.buttons, 1, -1 do
        local b = ui.buttons[i]
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
            b.fn()
            T.render(ui)
            return true
        end
    end
    return false
end

local function keyboardUI()
    for _, ui in ipairs(S.uis) do if ui.side == nil then return ui end end
    return nil
end

-- Monitors without touch show what the keyboard UI shows (same screen, same turtle).
local function follow(src)
    if not src then return end
    for _, ui in ipairs(S.uis) do
        if ui.follow and ui ~= src then
            for _, k in ipairs(NAV) do ui[k] = src[k] end
            local b = src.focus and src.buttons[src.focus]
            ui.focusKey = b and b.key or nil
            pcall(T.render, ui)
        end
    end
end
T.followKeyboard = function() follow(keyboardUI()) end

function T.renderAll()
    S.dirtyQueued = false
    local kb = keyboardUI()
    for _, ui in ipairs(S.uis) do
        if not ui.follow then pcall(T.render, ui) end
    end
    follow(kb)
end

-- A key or typed character from the PC's keyboard.
function T.keyInput(e, v)
    local ui = keyboardUI()
    if not ui then return end
    if e == "key" and T.navKey(ui, v) then
        -- handled: keyboard navigation (basic computers have no mouse)
    elseif ui.view == "num" then
        if e == "char" and v:match("^[0-9%-]$") then T.numKey(ui, v)
        elseif e == "key" and v == keys.backspace then T.numKey(ui, "DEL")
        elseif e == "key" and (v == keys.enter or v == keys.numPadEnter) then T.numOk(ui) end
        T.render(ui)
    end
    follow(ui)
end

-- ---------------------------------------------------------------------------
-- Displays
-- ---------------------------------------------------------------------------
local function findMonitor(sideArg)
    if sideArg == "none" then return nil end
    if sideArg and sideArg ~= "auto" and peripheral.getType(sideArg) == "monitor" then
        return peripheral.wrap(sideArg), sideArg
    end
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "monitor" then return peripheral.wrap(n), n end
    end
    return nil
end

function T.attachMonitor(cfg)
    local mon, side = findMonitor(cfg.monitor)
    if not mon then return end
    for _, ui in ipairs(S.uis) do if ui.side == side then return end end
    pcall(mon.setTextScale, cfg.scale)
    local ui = T.newUI(mon, side)
    -- Basic monitors have no colour and send no touch events: drive them from the keyboard.
    ui.follow = not ui.color
    table.insert(S.uis, 1, ui)
end

function T.uiLoop()
    T.renderAll()
    while true do
        local ev = { os.pullEvent() }
        local e = ev[1]
        if e == "tminer_redraw" then
            T.renderAll()
        elseif e == "monitor_touch" or e == "mouse_click" then
            for _, ui in ipairs(S.uis) do
                if (e == "monitor_touch" and ui.side == ev[2]) or (e == "mouse_click" and ui.side == nil) then
                    T.click(ui, ev[3], ev[4])
                end
            end
            if e == "mouse_click" then T.followKeyboard() end
        elseif e == "char" or e == "key" then
            T.keyInput(e, ev[2])
        elseif e == "monitor_resize" or e == "term_resize" then
            T.renderAll()
        elseif e == "peripheral" then
            if peripheral.getType(ev[2]) == "modem" then T.openModems() end
            if peripheral.getType(ev[2]) == "monitor" and S.mode == "server" then T.attachMonitor(S.cfg) end
            T.renderAll()
        elseif e == "peripheral_detach" then
            for i = #S.uis, 1, -1 do
                if S.uis[i].side == ev[2] then table.remove(S.uis, i) end
            end
            T.openModems()
            T.renderAll()
        end
    end
end

return T
