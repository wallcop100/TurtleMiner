-- Version: 1.1.0
-- Scenario 34:
--  A (review #19): miner/startup.lua runs the updater only when the journal says the
--     turtle is at home: R lines don't count, the last D (or S) line wins, a trailing I
--     line means "not at home".
--  B (review #8): monitor SET screen for every REMOTE_KEY, RESET_JOB/REBOOT confirms;
--     render fuzz over many screen sizes, never a write off screen.
--  C (review #9): the server forgets a turtle's home record on `home_clear`.

local function startupCases(sim, H)
    local CASES = {
        { "no state", nil, nil, true },
        { "snapshot at home", { 0, 0, 0 }, "S 0 0 0 0 100 1", true },
        { "away, then refuel", { 0, 0, 0 }, "S 0 0 0 0 100 1\nD 0 0 -1 0 99\nR 900", false },
        { "back home, then refuel", { 0, 0, 0 }, "S 0 0 0 0 100 1\nD 0 0 -1 0 99\nD 0 0 0 0 98\nR 900", true },
        { "move in flight", { 0, 0, 0 }, "S 0 0 0 0 100 1\nI f 100", false },
        { "move in flight, then refuel", { 0, 0, 0 }, "S 0 0 0 0 100 1\nD 0 0 0 0 99\nI f 99\nR 900", false },
        { "snapshot away, D home", { 0, -5, 0 }, "S 0 -5 0 0 100 1\nD 0 0 0 0 95", true },
        { "history D, snapshot away", { 0, -5, 0 }, "S 0 0 0 0 100 1\nD 0 0 0 0 95\nS 0 -5 0 0 90 2", false },
    }
    local results = {}
    for _, case in ipairs(CASES) do
        sim.reset()
        local w = sim.world()
        local t = sim.turtle(w, { id = 60, pos = { x = 0, y = 0, z = 0 }, facing = 0, fuel = 1000 })
        t.fs:write("updater.lua", 'return { run = function() local h = fs.open("upd_called", "w") h.write("1") h.close() return false end }')
        t.fs:write("miner.lua", "-- Version: 0.0.0\nreturn")
        if case[2] then
            local p = case[2]
            t.fs:write(".tm_state", sim.textutils.serialize({
                pos = { x = p[1], y = p[2], z = p[3] }, home = { x = 0, y = 0, z = 0 }, facing = 0, homeFacing = 0 }))
            t.fs:write(".tm_journal", case[3] .. "\n")
        end
        local r = sim.boot(t, { "startup" }, { maxTime = 60 })
        H.check(r.status == "exit", "startup case '%s' did not finish: %s %s", case[1], tostring(r.status), tostring(r.err))
        local called = t.fs:read("upd_called") ~= nil
        H.check(called == case[4], "startup case '%s': updater %s", case[1], called and "ran (turtle is not at home)" or "did not run")
        results[#results + 1] = case[1]
    end
    return #results
end

-- Minimal host-side CC environment for central_monitor.lua --lib.
local function monitorEnv(sim)
    local files, clock = {}, 0
    local fsx = {}
    function fsx.exists(p) return files[p] ~= nil end
    function fsx.delete(p) files[p] = nil end
    function fsx.move(a, b) files[b] = files[a]; files[a] = nil end
    function fsx.open(p, mode)
        if mode == "r" then
            if not files[p] then return nil end
            local s = files[p]
            return { readAll = function() return s end, close = function() end }
        end
        if mode == "w" then files[p] = "" end
        files[p] = files[p] or ""
        return { write = function(s) files[p] = files[p] .. s end, close = function() end }
    end
    local colors = {}
    for i, n in ipairs({ "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray", "lightGray",
        "cyan", "purple", "blue", "brown", "green", "red", "black" }) do colors[n] = 2 ^ (i - 1) end
    -- central_monitor.lua is a launcher: tminer_server.lua + tm_*.lua are loaded with loadfile
    for _, n in ipairs({ "tminer_server.lua", "tm_db.lua", "tm_radio.lua", "tm_cluster.lua", "tm_ui.lua",
        "tm_views.lua", "tm_update.lua" }) do
        local f = assert(io.open(sim.REPO .. "/servers/" .. n, "rb"))
        files[n] = f:read("a")
        f:close()
    end
    local env
    local function loadfileX(p, mode, e)
        if not files[p] then return nil, "File not found" end
        return load(files[p], "=" .. p, "t", e or env)
    end
    function fsx.isDir() return false end
    function fsx.getDir(p) return p:match("^(.*)/[^/]*$") or "" end
    function fsx.combine(a, b) return (a == "" and b) or (a .. "/" .. b) end
    env = {
        fs = fsx, colors = colors, colours = colors, textutils = sim.textutils, loadfile = loadfileX,
        os = {
            epoch = function() clock = clock + 1; return 1700000000000 + clock end,
            queueEvent = function() end, startTimer = function() return 1 end,
            date = function() return "01-01 00:00:00" end,
            getComputerID = function() return 100 end, getComputerLabel = function() return "srv" end,
        },
        peripheral = { getNames = function() return {} end, getType = function() return nil end, find = function() return nil end },
        rednet = { open = function() end, isOpen = function() return false end, broadcast = function() end },
        term = { current = function() return nil end },
        keys = {},
    }
    return setmetatable(env, { __index = _G }), files
end

local function fakeDevice(w, h, viol)
    local d, cx, cy = {}, 1, 1
    local rows = {}
    function d.getSize() return w, h end
    function d.isColor() return true end
    function d.setTextColor() end
    function d.setBackgroundColor() end
    function d.setCursorPos(x, y) cx, cy = x, y end
    function d.clear() rows = {} end
    function d.write(s)
        s = tostring(s)
        if cy < 1 or cy > h or cx < 1 or cx + #s - 1 > w then
            viol[#viol + 1] = string.format("%dx%d write %q at (%d,%d)", w, h, s, cx, cy)
        end
        local r = rows[cy] or string.rep(" ", w)
        if cy >= 1 and cy <= h then
            local a = math.max(1, cx)
            local txt = s:sub(a - cx + 1, w - cx + 1)
            rows[cy] = (r:sub(1, a - 1) .. txt .. r:sub(a + #txt)):sub(1, w)
        end
        cx = cx + #s
    end
    function d.text()
        local out = {}
        for y = 1, h do out[#out + 1] = rows[y] or "" end
        return table.concat(out, "\n")
    end
    return d
end

local function monitorCases(sim, H)
    local f = assert(io.open(sim.REPO .. "/servers/central_monitor.lua", "rb"))
    local src = f:read("a")
    f:close()
    local env, files = monitorEnv(sim)
    local M = assert(load(src, "=central_monitor", "t", env))("--lib")
    H.check(type(M) == "table" and M.SET_KEYS, "central_monitor --lib has no SET_KEYS")
    M.init({ mode = "server", noDisplay = true })
    local function status(id, label, phase)
        M.handleMessage(id, { v = 1, kind = "status", from = id, to = "server", boot = 1, seq = id * 1000 + 1, hops = 0,
            label = label, phase = phase, reason = "a long reason text that will not fit on a pocket screen",
            pos = { x = -1234, y = -58, z = 4567 }, facing = 1, home = { x = 0, y = 64, z = 0 }, gps = true,
            fuel = 123456, fuelNeeded = 300, slotsUsed = 7, job = { corridor = 1, branch = 3, side = "L", step = 12 },
            stats = { ores = 42, blocks = 900, trips = 3, uptime = 3600 }, cfg = { targetY = -58, focus = "all" } }, "TMINER")
    end
    status(41, "Alpha-with-a-long-name", "MINING")
    status(42, "Bravo", "NEEDS_HELP")

    -- C: home_clear
    M.handleMessage(42, { v = 1, kind = "home_save", from = 42, to = "server", boot = 1, seq = 5, hops = 0,
        home = { x = 1, y = 2, z = 3 }, homeFacing = 0, gps = true }, "TMINER")
    H.check(M.S.homes[42], "home_save not stored")
    M.handleMessage(42, { v = 1, kind = "home_clear", from = 42, to = "server", boot = 1, seq = 6, hops = 0 }, "TMINER")
    H.check(M.S.homes[42] == nil, "home_clear did not remove the record")
    H.check(not tostring(files["miner_homes.db"] or ""):find("y = 2", 1, true), "home_clear not saved to disk")

    -- B: SET screens at 26x20 (pocket)
    local viol = {}
    local dev = fakeDevice(26, 20, viol)
    local ui = M.newUI(dev, nil)
    ui.sel = 41
    ui.view = "keys"
    M.render(ui)
    local text = dev.text()
    for _, k in ipairs(M.SET_KEYS) do
        H.check(text:find(k[2], 1, true), "key %s not listed on the 26x20 SET screen:\n%s", k[2], text)
    end
    local function clickLabel(label)
        local y = 0
        for row in (dev.text() .. "\n"):gmatch("(.-)\n") do
            y = y + 1
            local from = 1
            while true do
                local x = row:find(label, from, true)
                if not x then break end
                for _, b in ipairs(ui.buttons) do
                    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
                        M.click(ui, x, y)
                        return
                    end
                end
                from = x + 1
            end
        end
        H.fail("no button labelled %q on screen:\n%s", label, dev.text())
    end
    local function lastSent()
        local best
        for _, p in pairs(M.S.pending) do if not best or p.id > best.id then best = p end end
        return best
    end
    -- number key: MAX_CORRIDORS = 12
    clickLabel("CORRIDORS")
    H.check(ui.view == "num", "CORRIDORS opened view %s", ui.view)
    clickLabel("1"); clickLabel("2"); clickLabel("OK")
    local p = lastSent()
    H.check(p and p.cmd == "SET" and p.params.key == "MAX_CORRIDORS" and p.params.value == 12,
        "MAX_CORRIDORS 12 not sent (%s %s=%s)", tostring(p and p.cmd), tostring(p and p.params.key), tostring(p and p.params.value))
    M.S.pending = {}
    -- bool key
    ui.view = "keys"; M.render(ui)
    clickLabel("DROP_TRASH")
    H.check(ui.view == "bool", "DROP_TRASH opened view %s", ui.view)
    clickLabel("FALSE")
    p = lastSent()
    H.check(p and p.params.key == "DROP_TRASH" and p.params.value == false, "DROP_TRASH=false not sent")
    M.S.pending = {}
    -- string key
    ui.view = "keys"; M.render(ui)
    clickLabel("FOCUS")
    H.check(ui.view == "focus", "FOCUS opened view %s", ui.view)
    clickLabel("diamond")
    p = lastSent()
    H.check(p and p.params.key == "FOCUS" and p.params.value == "diamond", "FOCUS=diamond not sent")
    M.S.pending = {}
    -- out of range number is refused locally
    ui.view = "keys"; M.render(ui)
    clickLabel("BRANCH_SPC")
    clickLabel("9"); clickLabel("OK")
    H.check(lastSent() == nil and ui.view == "num", "BRANCH_SPACING 9 was sent (range 2..8)")
    -- confirms
    for _, c in ipairs({ { "RESET JOB", "RESET_JOB" }, { "REBOOT", "REBOOT" }, { "RESET HOME", "RESET_HOME" } }) do
        M.S.pending = {}
        ui.view = "cmds"; M.render(ui)
        clickLabel(c[1])
        H.check(ui.view == "confirm", "%s did not ask for confirmation (view %s)", c[1], ui.view)
        clickLabel("YES")
        p = lastSent()
        H.check(p and p.cmd == c[2], "%s not sent after YES", c[2])
    end
    H.check(#viol == 0, "26x20: %d writes off screen, first %s", #viol, viol[1] or "")

    -- render fuzz: every view, many sizes, and every button clicked once per view
    local VIEWS = { "list", "detail", "cmds", "num", "focus", "keys", "bool", "confirm", "text", "log" }
    local sizes = {}
    for w = 1, 40 do sizes[#sizes + 1] = { w, (w * 7) % 30 + 1 } end
    for h = 1, 30 do sizes[#sizes + 1] = { 26, h } end
    for _, wh in ipairs({ { 26, 20 }, { 39, 13 }, { 51, 19 }, { 82, 40 }, { 164, 81 }, { 7, 5 }, { 15, 10 } }) do sizes[#sizes + 1] = wh end
    local renders = 0
    for _, wh in ipairs(sizes) do
        local d = fakeDevice(wh[1], wh[2], viol)
        local u = M.newUI(d, nil)
        for _, v in ipairs(VIEWS) do
            for _, key in ipairs({ "TARGET_Y", "FUEL_TARGET", "BURN_COAL" }) do
                u.view, u.sel, u.setKey, u.input, u.text = v, 41, key, "-12", "x"
                u.confirmCmd = ({ "RESET_JOB", "REBOOT", "RESET_HOME" })[renders % 3 + 1]
                local ok, err = pcall(M.render, u)
                H.check(ok, "render %s at %dx%d crashed: %s", v, wh[1], wh[2], tostring(err))
                renders = renders + 1
                local btns = {}
                for i, b in ipairs(u.buttons) do btns[i] = b end
                for _, b in ipairs(btns) do
                    u.view, u.sel, u.setKey = v, 41, key
                    pcall(M.render, u)
                    local okc, errc = pcall(M.click, u, b.x1, b.y1)
                    H.check(okc, "click in %s at %dx%d crashed: %s", v, wh[1], wh[2], tostring(errc))
                end
            end
        end
        H.check(#viol == 0, "%d writes off screen, first %s", #viol, viol[1] or "")
    end
    return renders
end

return {
    title = "startup at-home check, monitor SET screens + fuzz, home_clear",
    needs = {},
    run = function(sim, H)
        local n = startupCases(sim, H)
        local renders = monitorCases(sim, H)
        return string.format("%d startup cases; %d monitor renders without overflow", n, renders)
    end,
}
