-- Version: 1.0.0
-- TurtleMiner server UI, part 2: the turtle card, command buttons, SET pickers (number,
-- yes/no, focus ore), confirmations and the text / event log views. Drawing helpers come
-- from tm_ui.lua (T.ui); each screen registers itself in T.VIEWS.
local T = ...
local S = T.S
local U = T.ui
local trunc, pad = T.trunc, T.pad
local labelOf, nameOf = T.labelOf, T.nameOf
local put, button, zone, header = U.put, U.button, U.zone, U.header
local gridCols, buttonGrid, currentRec, doCmd = U.gridCols, U.buttonGrid, U.currentRec, U.doCmd
local renderList, detailLines, posStr = U.renderList, U.detailLines, U.posStr
local fillLine = U.fillLine

T.FOCUS_LIST = {
    "all", "diamond", "iron", "gold", "copper", "redstone", "lapis",
    "emerald", "coal", "ancient_debris", "nether_quartz", "nether_gold",
}
-- Keys the turtle accepts with SET (miner/config.lua REMOTE_KEYS). The server can't
-- load config.lua, so the list lives here too: {key, short label, type, min, max}.
T.SET_KEYS = {
    { "TARGET_Y",        "TARGET_Y",    "number", -64, 320 },
    { "HOME_Y",          "HOME_Y",      "number", -64, 320 },
    { "BRANCH_LENGTH",   "BRANCH_LEN",  "number", 4, 128 },
    { "BRANCH_SPACING",  "BRANCH_SPC",  "number", 2, 8 },
    { "MAIN_LENGTH",     "MAIN_LEN",    "number", 8, 256 },
    { "MAX_CORRIDORS",   "CORRIDORS",   "number", 1, 64 },
    { "FOCUS",           "FOCUS",       "string" },
    { "VEIN_MINING",     "VEIN_MINING", "bool" },
    { "VEIN_MAX",        "VEIN_MAX",    "number", 1, 512 },
    { "DROP_TRASH",      "DROP_TRASH",  "bool" },
    { "FUEL_MARGIN",     "FUEL_MARGIN", "number", 0, 10000 },
    { "FUEL_KEEP",       "FUEL_KEEP",   "number", 0, 64 },
    { "FUEL_TARGET",     "FUEL_TARGET", "number", 0, 100000 },
    { "BURN_COAL",       "BURN_COAL",   "bool" },
    { "STATUS_INTERVAL", "STATUS_INT",  "number", 2, 120 },
    { "AUTO_UPDATE",     "AUTO_UPDATE", "bool" },
    { "SURFACE_IF_LOST", "SURF_LOST",   "bool" },
}

local SET_KEYS, FOCUS_LIST = T.SET_KEYS, T.FOCUS_LIST

local function keyDef(key)
    for _, d in ipairs(SET_KEYS) do if d[1] == key then return d end end
    return nil
end

-- Open the value screen for one SET key.
local function editKey(ui, r, key)
    local d = keyDef(key)
    if not d then return end
    ui.setKey, ui.msg = key, nil
    if d[3] == "string" then
        ui.view = "focus"
    elseif d[3] == "bool" then
        ui.view = "bool"
    else
        local c = key == "TARGET_Y" and type(r.st.cfg) == "table" and r.st.cfg.targetY
        ui.input = c and tostring(c) or ""
        ui.view = "num"
    end
end

local CONFIRM = {
    RESET_HOME = { "Reset home?", "YES RESET", function(r)
        return "Set the home of " .. nameOf(r) .. " to where it is NOW (" .. posStr(r.st.pos)
            .. ")? Only do this when it sits at its home chest."
    end },
    RESET_JOB = { "Reset job?", "YES RESET", function(r)
        return "Restart the mining grid of " .. nameOf(r) .. " at corridor 0 next time it is home?"
            .. " Already mined tunnels are walked again. Send RESUME if it is DONE or IDLE."
    end },
    REBOOT = { "Reboot?", "YES REBOOT", function(r)
        return "Reboot " .. nameOf(r) .. "? It saves first and carries on after the restart."
    end },
}

local function confirm(ui, cmd)
    ui.confirmCmd = cmd
    ui.view = "confirm"
end

local function cmdDefs(ui, r)
    return {
        { "RETURN HOME", colors.orange, function() doCmd(ui, "RETURN_HOME") end },
        { "PAUSE", colors.yellow, function() doCmd(ui, "PAUSE") end, colors.black },
        { "RESUME", colors.green, function() doCmd(ui, "RESUME") end },
        { "STATUS", colors.blue, function() doCmd(ui, "REQUEST_STATUS") end },
        { "TARGET Y", colors.blue, function() editKey(ui, r, "TARGET_Y") end },
        { "FOCUS ORE", colors.blue, function() editKey(ui, r, "FOCUS") end },
        { "SET...", colors.blue, function() ui.view = "keys" end },
        { "UPDATE", colors.purple, function() doCmd(ui, "UPDATE") end },
        { "RESET JOB", colors.red, function() confirm(ui, "RESET_JOB") end },
        { "RESET HOME", colors.red, function() confirm(ui, "RESET_HOME") end },
        { "REBOOT", colors.red, function() confirm(ui, "REBOOT") end },
        { "BACK", colors.gray, function() ui.view = "list" end },
    }
end

local CORE_LINES = 12

local function renderDetail(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    header(ui, labelOf(r) .. " #" .. r.id, nil, true)
    local defs = cmdDefs(ui, r)
    local lines = detailLines(r, ui.w >= 40)
    local gridRows = math.ceil(#defs / gridCols(ui, 3))
    local lastInfo
    if ui.h - 2 - gridRows < math.min(CORE_LINES, 6) then
        -- small screen: info on this page, commands on their own page
        local half = math.max(1, math.floor((ui.w - 3) / 2))
        button(ui, 2, ui.h, half, "BACK", colors.gray, function() ui.view = "list" end)
        button(ui, 3 + half, ui.h, half, "CMDS", colors.blue, function() ui.view = "cmds" end)
        lastInfo = ui.h - 1
    else
        local top = buttonGrid(ui, defs, 3, #lines + 1)
        lastInfo = top - 2
        if lastInfo < 2 then lastInfo = top - 1 end
    end
    local kw = 7
    for i, l in ipairs(lines) do
        local y = 1 + i
        if y > lastInfo then break end
        put(ui, 1, y, pad(l[1], kw - 1), colors.lightGray)
        put(ui, kw, y, trunc(l[2], ui.w - kw + 1), l[3] or colors.white)
        local full = l[1] .. ": " .. l[2]
        zone(ui, 1, y, ui.w, y, function() ui.text = full; ui.view = "text" end, "f:" .. i)
    end
end

local function renderCmds(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    header(ui, "Cmd " .. labelOf(r) .. " #" .. r.id, nil, true)
    local defs = cmdDefs(ui, r)
    defs[#defs][3] = function() ui.view = "detail" end
    buttonGrid(ui, defs, 3)
end

-- Key picker (SET any remote key) -------------------------------------------
local function renderKeys(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    header(ui, "Set #" .. r.id, nil, true)
    local defs = {}
    for _, d in ipairs(SET_KEYS) do
        local key = d[1]
        defs[#defs + 1] = { d[2], colors.blue, function() editKey(ui, r, key) end }
    end
    defs[#defs + 1] = { "CANCEL", colors.red, function() ui.view = "detail" end }
    buttonGrid(ui, defs, 4)
end

-- Boolean entry ---------------------------------------------------------------
local function renderBool(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    local d = keyDef(ui.setKey)
    if not d or d[3] ~= "bool" then d = keyDef("VEIN_MINING") end
    header(ui, d[2] .. " #" .. r.id, nil, true)
    put(ui, 1, 2, trunc("Set " .. d[1] .. " to:", ui.w), colors.lightGray)
    buttonGrid(ui, {
        { "TRUE", colors.green, function() doCmd(ui, "SET", { key = d[1], value = true }) end },
        { "FALSE", colors.orange, function() doCmd(ui, "SET", { key = d[1], value = false }) end },
        { "CANCEL", colors.red, function() ui.view = "detail" end },
    }, 3, 1)
end

-- Numeric entry (any number key) ----------------------------------------------
local function numKeyDef(ui)
    local d = keyDef(ui.setKey)
    if not d or d[3] ~= "number" then d = keyDef("TARGET_Y") end
    return d
end

local function numOk(ui)
    local d = numKeyDef(ui)
    local v = tonumber(ui.input)
    if not v or v ~= math.floor(v) or v < d[4] or v > d[5] then
        ui.msg = "Need integer " .. d[4] .. ".." .. d[5]
        return
    end
    doCmd(ui, "SET", { key = d[1], value = v })
end

local function numKey(ui, ch)
    local d = numKeyDef(ui)
    local maxLen = math.max(#tostring(d[4]), #tostring(d[5]))
    if ch == "DEL" then ui.input = ui.input:sub(1, -2)
    elseif ch == "-" then
        if d[4] < 0 then
            if ui.input:sub(1, 1) == "-" then ui.input = ui.input:sub(2) else ui.input = "-" .. ui.input end
        end
    elseif #ui.input:gsub("^%-", "") < maxLen then ui.input = ui.input .. ch end
    ui.msg = nil
end

local function renderNum(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    local d = numKeyDef(ui)
    header(ui, d[2] .. " #" .. r.id, nil, true)
    local lbl = d[2] .. " = "
    if #lbl > math.floor(ui.w / 2) then lbl = "= " end
    put(ui, 1, 2, lbl, colors.lightGray)
    put(ui, #lbl + 1, 2, ui.input .. "_", colors.yellow)
    if ui.msg then put(ui, 1, 3, trunc(ui.msg, ui.w), colors.red)
    else put(ui, 1, 3, trunc("range " .. d[4] .. ".." .. d[5], ui.w), colors.gray) end
    local defs = {}
    for _, k in ipairs({ "7", "8", "9", "DEL", "4", "5", "6", "-", "1", "2", "3", "0" }) do
        defs[#defs + 1] = { k, colors.gray, function() numKey(ui, k) end }
    end
    defs[#defs + 1] = { "CANCEL", colors.red, function() ui.view = "detail" end }
    defs[#defs + 1] = { "", colors.black, function() end }
    defs[#defs + 1] = { "", colors.black, function() end }
    defs[#defs + 1] = { "OK", colors.green, function() numOk(ui) end }
    -- 4 columns regardless of width (keys are short)
    local cols, rows = 4, 4
    local bw = math.max(1, math.floor((ui.w - 5) / 4))
    local gap = (ui.h - 4 >= rows * 2) and 1 or 0
    local top = math.max(4, ui.h - (rows * (1 + gap) - gap) + 1)
    for i, d in ipairs(defs) do
        local c, rr = (i - 1) % cols, math.floor((i - 1) / cols)
        if d[1] ~= "" then button(ui, 2 + c * (bw + 1), top + rr * (1 + gap), bw, d[1], d[2], d[3]) end
    end
end

-- Focus ore picker ---------------------------------------------------------
local function renderFocus(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    header(ui, "Focus ore #" .. r.id, nil, true)
    local cur = type(r.st.cfg) == "table" and r.st.cfg.focus
    local defs = {}
    for _, f in ipairs(FOCUS_LIST) do
        defs[#defs + 1] = { f, f == cur and colors.green or colors.blue,
            function() doCmd(ui, "SET", { key = "FOCUS", value = f }) end }
    end
    defs[#defs + 1] = { "CANCEL", colors.red, function() ui.view = "detail" end }
    buttonGrid(ui, defs, 3)
end

-- Confirm RESET_HOME / RESET_JOB / REBOOT ------------------------------------
local function wrap(text, w)
    local out = {}
    if w < 1 then return out end
    for para in (tostring(text) .. "\n"):gmatch("(.-)\n") do
        while #para > w do
            local cut = para:sub(1, w):match("^.*() ") or (w + 1)
            if cut <= 1 then cut = w + 1 end
            out[#out + 1] = para:sub(1, cut - 1)
            para = para:sub(cut):gsub("^ ", "")
        end
        out[#out + 1] = para
    end
    return out
end

local function renderConfirm(ui)
    local r = currentRec(ui)
    if not r then ui.view = "list"; return renderList(ui) end
    local cmd = CONFIRM[ui.confirmCmd] and ui.confirmCmd or "RESET_HOME"
    local c = CONFIRM[cmd]
    header(ui, c[1], nil, true)
    local lines = wrap(c[3](r), ui.w)
    for i, l in ipairs(lines) do
        if 1 + i > ui.h - 2 then break end
        put(ui, 1, 1 + i, l, colors.white)
    end
    local half = math.max(1, math.floor((ui.w - 3) / 2))
    button(ui, 2, ui.h, half, c[2], colors.red, function() doCmd(ui, cmd, {}) end)
    button(ui, 3 + half, ui.h, half, "NO", colors.gray, function() ui.view = "detail" end)
end

-- Text view (full field / log) ----------------------------------------------
local function renderText(ui, title, lines, back)
    fillLine(ui, 1, colors.blue)
    button(ui, 1, 1, 3, "<", colors.gray, back)
    put(ui, 5, 1, trunc(title, ui.w - 4), colors.white, colors.blue)
    local avail = ui.h - 1
    local first = math.max(1, #lines - avail + 1)
    for i = first, #lines do
        put(ui, 1, 2 + i - first, trunc(lines[i], ui.w), colors.white)
    end
    zone(ui, 1, 2, ui.w, ui.h, back)
end

T.cmdDefs, T.numKey, T.numOk, T.wrap = cmdDefs, numKey, numOk, wrap
T.VIEWS.detail, T.VIEWS.cmds, T.VIEWS.num, T.VIEWS.focus = renderDetail, renderCmds, renderNum, renderFocus
T.VIEWS.keys, T.VIEWS.bool, T.VIEWS.confirm = renderKeys, renderBool, renderConfirm
T.VIEWS.text = function(ui)
    renderText(ui, "Detail", wrap(ui.text or "", ui.w), function() ui.view = "detail" end)
end
T.VIEWS.log = function(ui)
    local lines = {}
    for _, l in ipairs(S.log) do for _, p in ipairs(wrap(l, ui.w)) do lines[#lines + 1] = p end end
    renderText(ui, "Event log", lines, function() ui.view = "list" end)
end

return T
