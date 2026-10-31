-- Version: 1.0.0
-- Terminal objects for the simulator. A term is a table of functions called
-- with "." like CC's. With opts.strict, any write that falls outside the
-- screen is recorded in obj._violations (and the write is clipped).

local Term = {}

local BLIT = "0123456789abcdef"
local function toBlit(c)
    local i = 0
    while c > 1 do c = c / 2; i = i + 1 end
    return BLIT:sub(i + 1, i + 1)
end

function Term.new(w, h, opts)
    opts = opts or {}
    local t = {}
    local cx, cy = 1, 1
    local fg, bg = 1, 32768
    local blink = false
    local lines, fgl, bgl = {}, {}, {}
    local violations = {}
    local scale = 1

    local function clearRow(y)
        lines[y] = string.rep(" ", w)
        fgl[y] = string.rep(toBlit(fg), w)
        bgl[y] = string.rep(toBlit(bg), w)
    end
    for y = 1, h do clearRow(y) end

    local function put(text, fgs, bgs)
        text = tostring(text)
        local n = #text
        if n == 0 then return end
        local oob = cy < 1 or cy > h or cx < 1 or cx + n - 1 > w
        if oob and opts.strict then
            violations[#violations + 1] = { x = cx, y = cy, text = text, w = w, h = h }
        end
        if cy >= 1 and cy <= h then
            local row, frow, brow = lines[cy], fgl[cy], bgl[cy]
            for i = 1, n do
                local x = cx + i - 1
                if x >= 1 and x <= w then
                    row = row:sub(1, x - 1) .. text:sub(i, i) .. row:sub(x + 1)
                    frow = frow:sub(1, x - 1) .. fgs:sub(i, i) .. frow:sub(x + 1)
                    brow = brow:sub(1, x - 1) .. bgs:sub(i, i) .. brow:sub(x + 1)
                end
            end
            lines[cy], fgl[cy], bgl[cy] = row, frow, brow
        end
        cx = cx + n
    end

    function t.write(text)
        text = tostring(text)
        put(text, string.rep(toBlit(fg), #text), string.rep(toBlit(bg), #text))
    end
    function t.blit(text, f, b)
        if #text ~= #f or #text ~= #b then error("Arguments must be the same length", 2) end
        put(text, f, b)
    end
    function t.clear() for y = 1, h do clearRow(y) end end
    function t.clearLine() if cy >= 1 and cy <= h then clearRow(cy) end end
    function t.getCursorPos() return cx, cy end
    function t.setCursorPos(x, y) cx, cy = math.floor(x), math.floor(y) end
    function t.setCursorBlink(b) blink = b end
    function t.getCursorBlink() return blink end
    function t.isColor() return opts.color ~= false end
    t.isColour = t.isColor
    function t.getSize() return w, h end
    function t.scroll(n)
        n = math.floor(n or 1)
        if n > 0 then
            for y = 1, h do
                if y + n <= h then lines[y], fgl[y], bgl[y] = lines[y + n], fgl[y + n], bgl[y + n] else clearRow(y) end
            end
        elseif n < 0 then
            for y = h, 1, -1 do
                if y + n >= 1 then lines[y], fgl[y], bgl[y] = lines[y + n], fgl[y + n], bgl[y + n] else clearRow(y) end
            end
        end
    end
    function t.setTextColor(c) fg = c end
    t.setTextColour = t.setTextColor
    function t.getTextColor() return fg end
    t.getTextColour = t.getTextColor
    function t.setBackgroundColor(c) bg = c end
    t.setBackgroundColour = t.setBackgroundColor
    function t.getBackgroundColor() return bg end
    t.getBackgroundColour = t.getBackgroundColor
    function t.setPaletteColor() end
    t.setPaletteColour = t.setPaletteColor
    function t.getPaletteColor() return 0, 0, 0 end
    t.getPaletteColour = t.getPaletteColor
    function t.nativePaletteColor() return 0, 0, 0 end
    t.nativePaletteColour = t.nativePaletteColor
    function t.getLine(y) return lines[y], fgl[y], bgl[y] end
    if opts.monitor then
        function t.setTextScale(s) scale = s end
        function t.getTextScale() return scale end
    end

    -- sim-only accessors (underscore so programs won't stumble on them)
    t._violations = violations
    function t._lines() local r = {}; for y = 1, h do r[y] = lines[y] end; return r end
    function t._text() return table.concat(t._lines(), "\n") end
    return t
end

-- window API (subset): a sub-rectangle that writes through to its parent and
-- clips at its own edges, like CC's window.
function Term.window(parent, wx, wy, ww, wh, visible)
    if visible == nil then visible = true end
    local inner = Term.new(ww, wh, { strict = false })
    local w = {}
    for k, f in pairs(inner) do
        if type(f) == "function" and k:sub(1, 1) ~= "_" then
            w[k] = function(...) return inner[k](...) end
        end
    end
    local function redrawLine(y)
        if not visible then return end
        local text, f, b = inner.getLine(y)
        if not text then return end
        local px, py = parent.getCursorPos()
        parent.setCursorPos(wx, wy + y - 1)
        parent.blit(text, f, b)
        parent.setCursorPos(px, py)
    end
    local function redraw() for y = 1, wh do redrawLine(y) end end
    local function wrapLine(name)
        return function(...)
            local _, y = inner.getCursorPos()
            local r = table.pack(inner[name](...))
            redrawLine(y)
            return table.unpack(r, 1, r.n)
        end
    end
    w.write = wrapLine("write")
    w.blit = wrapLine("blit")
    w.clearLine = wrapLine("clearLine")
    w.clear = function() inner.clear(); redraw() end
    w.scroll = function(n) inner.scroll(n); redraw() end
    w.setVisible = function(v) visible = v; if v then redraw() end end
    w.isVisible = function() return visible end
    w.redraw = redraw
    w.restoreCursor = function() local x, y = inner.getCursorPos(); parent.setCursorPos(wx + x - 1, wy + y - 1) end
    w.getPosition = function() return wx, wy end
    w.reposition = function(nx, ny, nw, nh)
        wx, wy = nx, ny
        if nw and nh and (nw ~= ww or nh ~= wh) then
            ww, wh = nw, nh
            inner = Term.new(ww, wh, {})
        end
        redraw()
    end
    return w
end

return Term
