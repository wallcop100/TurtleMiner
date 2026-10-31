-- Version: 1.0.0
-- textutils for the simulator: serialize/unserialize compatible with CC
-- (output is a Lua literal; unserialize loads it in an empty env).

local textutils = {}

local KEYWORDS = {}
for w in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%a+") do
    KEYWORDS[w] = true
end

local function numstr(n)
    if n ~= n then return "0/0" end
    if n == math.huge then return "1/0" end
    if n == -math.huge then return "-1/0" end
    if n == math.floor(n) and n > -2 ^ 53 and n < 2 ^ 53 then return string.format("%d", n) end
    return string.format("%.17g", n)
end
textutils._numstr = numstr

local function keyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end

local function ser(v, tracking, indent, compact)
    local tp = type(v)
    if tp == "table" then
        if tracking[v] then error("Cannot serialize table with recursive entries", 0) end
        tracking[v] = true
        if next(v) == nil then tracking[v] = nil; return "{}" end
        local nl = compact and "" or "\n"
        local sub = compact and "" or indent .. "  "
        local eq = compact and "=" or " = "
        local out = { "{" .. nl }
        local seen = {}
        for i, item in ipairs(v) do
            seen[i] = true
            out[#out + 1] = sub .. ser(item, tracking, sub, compact) .. "," .. nl
        end
        local keys = {}
        for k in pairs(v) do if not seen[k] then keys[#keys + 1] = k end end
        table.sort(keys, keyLess)
        for _, k in ipairs(keys) do
            local ks
            if type(k) == "string" and not KEYWORDS[k] and k:match("^[%a_][%w_]*$") then
                ks = k .. eq
            else
                ks = "[ " .. ser(k, tracking, sub, compact) .. " ]" .. eq
            end
            out[#out + 1] = sub .. ks .. ser(v[k], tracking, sub, compact) .. "," .. nl
        end
        out[#out + 1] = indent .. "}"
        tracking[v] = nil
        return table.concat(out)
    elseif tp == "string" then
        return string.format("%q", v)
    elseif tp == "number" then
        return numstr(v)
    elseif tp == "boolean" or tp == "nil" then
        return tostring(v)
    end
    error("Cannot serialize type " .. tp, 0)
end

function textutils.serialize(v, opts)
    local compact = type(opts) == "table" and opts.compact or false
    return ser(v, {}, "", compact)
end
textutils.serialise = textutils.serialize

function textutils.unserialize(s)
    if type(s) ~= "string" then return nil end
    local f = load("return " .. s, "unserialize", "t", {})
    if not f then return nil end
    local ok, r = pcall(f)
    if ok then return r end
    return nil
end
textutils.unserialise = textutils.unserialize

-- JSON ---------------------------------------------------------------------
local function jsonStr(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
        return m[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function json(v, tracking)
    local tp = type(v)
    if tp == "table" then
        if tracking[v] then error("Cannot serialize table with recursive entries", 0) end
        tracking[v] = true
        local n = #v
        local isArr = n > 0
        if isArr then for k in pairs(v) do if type(k) ~= "number" or k > n or k < 1 then isArr = false break end end end
        local out = {}
        if isArr then
            for i = 1, n do out[i] = json(v[i], tracking) end
            tracking[v] = nil
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, keyLess)
        for _, k in ipairs(keys) do out[#out + 1] = jsonStr(tostring(k)) .. ":" .. json(v[k], tracking) end
        tracking[v] = nil
        return "{" .. table.concat(out, ",") .. "}"
    elseif tp == "string" then return jsonStr(v)
    elseif tp == "number" then return numstr(v)
    elseif tp == "boolean" then return tostring(v)
    elseif tp == "nil" then return "null" end
    error("Cannot serialize type " .. tp, 0)
end

function textutils.serializeJSON(v) return json(v, {}) end
textutils.serialiseJSON = textutils.serializeJSON

function textutils.unserializeJSON(s)
    -- minimal decoder: enough for round-tripping our own output
    local pos = 1
    local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local val
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local c = s:sub(pos, pos)
            if c == "" then error("unterminated string") end
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                local m = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" }
                if e == "u" then
                    out[#out + 1] = utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16)); pos = pos + 6
                else
                    out[#out + 1] = m[e] or e; pos = pos + 2
                end
            else
                out[#out + 1] = c; pos = pos + 1
            end
        end
        return table.concat(out)
    end
    function val()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local r = {}
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return r end
            while true do
                ws()
                local k = str()
                ws(); pos = pos + 1 -- :
                r[k] = val()
                ws()
                local d = s:sub(pos, pos); pos = pos + 1
                if d == "}" then return r end
            end
        elseif c == "[" then
            pos = pos + 1
            local r = {}
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return r end
            while true do
                r[#r + 1] = val()
                ws()
                local d = s:sub(pos, pos); pos = pos + 1
                if d == "]" then return r end
            end
        elseif c == '"' then return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else
            local num = s:match("^-?[%d%.eE+-]+", pos)
            if not num then error("unexpected " .. c) end
            pos = pos + #num
            return tonumber(num)
        end
    end
    local ok, r = pcall(val)
    if ok then return r end
    return nil, r
end
textutils.unserialiseJSON = textutils.unserializeJSON

function textutils.formatTime(t, h24)
    local h = math.floor(t) % 24
    local m = math.floor((t - math.floor(t)) * 60)
    if h24 then return string.format("%d:%02d", h, m) end
    local ampm = h >= 12 and "PM" or "AM"
    local hh = h % 12
    if hh == 0 then hh = 12 end
    return string.format("%d:%02d %s", hh, m, ampm)
end

function textutils.urlEncode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

textutils.empty_json_array = setmetatable({}, { __tostring = function() return "[]" end })
textutils.json_null = setmetatable({}, { __tostring = function() return "null" end })

return textutils
