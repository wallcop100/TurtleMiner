-- Version: 1.0.0
-- In-memory file system, one per simulated computer. Persists across boots
-- of that computer (and across sim.rollback, which only touches the world).
--
-- FS.new()            -> store (host-side: store:read(path), store:write(path, s))
-- FS.api(store, comp) -> the CC `fs` table for a running program. Every
--   mutating call goes through comp:check(evt) so a test's crashAt can kill
--   the computer at that point:
--     {kind="fs_open",   path, mode}
--     {kind="fs_close",  path, mode, data}   -- crash here leaves a truncated write
--     {kind="fs_delete", path}
--     {kind="fs_move",   from, to}
--     {kind="fs_copy",   from, to}

local FS = {}
FS.__index = FS

local function norm(path)
    path = tostring(path or ""):gsub("\\", "/")
    local parts = {}
    for p in path:gmatch("[^/]+") do
        if p == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif p ~= "." then
            parts[#parts + 1] = p
        end
    end
    return table.concat(parts, "/")
end
FS.norm = norm

local function dirname(p)
    p = norm(p)
    local d = p:match("^(.*)/[^/]*$")
    return d or ""
end

local function basename(p)
    p = norm(p)
    return p:match("([^/]*)$") or p
end

function FS.new()
    return setmetatable({ files = {}, dirs = { [""] = true } }, FS)
end

-- Host-side helpers (no hooks) ------------------------------------------------
function FS:mkdirs(p)
    p = norm(p)
    while p ~= "" and not self.dirs[p] do
        self.dirs[p] = true
        p = dirname(p)
    end
end

function FS:write(path, content)
    path = norm(path)
    self:mkdirs(dirname(path))
    self.files[path] = content
end

function FS:read(path)
    return self.files[norm(path)]
end

function FS:exists(path)
    path = norm(path)
    return self.files[path] ~= nil or self.dirs[path] ~= nil
end

function FS:remove(path)
    path = norm(path)
    self.files[path] = nil
    if self.dirs[path] and path ~= "" then
        local prefix = path .. "/"
        for k in pairs(self.files) do if k:sub(1, #prefix) == prefix then self.files[k] = nil end end
        for k in pairs(self.dirs) do if k:sub(1, #prefix) == prefix then self.dirs[k] = nil end end
        self.dirs[path] = nil
    end
end

function FS:list(path)
    path = norm(path)
    local prefix = path == "" and "" or path .. "/"
    local seen, out = {}, {}
    local function add(k)
        if k ~= "" and k:sub(1, #prefix) == prefix then
            local rest = k:sub(#prefix + 1)
            local name = rest:match("^([^/]+)")
            if name and not seen[name] then seen[name] = true; out[#out + 1] = name end
        end
    end
    for k in pairs(self.files) do add(k) end
    for k in pairs(self.dirs) do add(k) end
    table.sort(out)
    return out
end

-- CC API ------------------------------------------------------------------------
function FS.api(store, comp)
    local api = {}
    local function check(evt)
        if comp and comp.check then return comp:check(evt) end
        return false
    end
    local function halt(evt)
        if comp and comp.halt then comp:halt(evt) end
    end
    local function guard()
        if comp and comp.guard then comp:guard() end
    end
    local function ro(p)
        return p == "rom" or p:sub(1, 4) == "rom/"
    end

    function api.combine(...)
        local parts = { ... }
        for i = 1, #parts do parts[i] = tostring(parts[i]) end
        return norm(table.concat(parts, "/"))
    end
    function api.getName(p) local b = basename(p); return b == "" and "root" or b end
    function api.getDir(p) p = norm(p); if p == "" then return ".." end; return dirname(p) end
    function api.exists(p) return store:exists(p) end
    function api.isDir(p) return store.dirs[norm(p)] ~= nil end
    function api.isReadOnly(p) return ro(norm(p)) end
    function api.getSize(p)
        p = norm(p)
        if store.files[p] then return #store.files[p] end
        if store.dirs[p] then return 0 end
        error("/" .. p .. ": No such file", 2)
    end
    function api.getFreeSpace() return 1000000 end
    function api.getCapacity() return 1000000 end
    function api.getDrive(p) if store:exists(p) then return "hdd" end return nil end
    function api.isDriveRoot(p) return norm(p) == "" end
    function api.attributes(p)
        p = norm(p)
        if not store:exists(p) then error("/" .. p .. ": No such file", 2) end
        return { size = store.files[p] and #store.files[p] or 0, isDir = store.dirs[p] ~= nil,
                 isReadOnly = ro(p), created = 0, modified = 0, modification = 0 }
    end
    function api.list(p)
        p = norm(p)
        if not store.dirs[p] then error("/" .. p .. ": Not a directory", 2) end
        return store:list(p)
    end
    function api.makeDir(p)
        guard()
        p = norm(p)
        if store.files[p] then error("/" .. p .. ": File exists", 2) end
        store:mkdirs(p)
    end
    function api.delete(p)
        guard()
        p = norm(p)
        if ro(p) then error("/" .. p .. ": Access denied", 2) end
        local evt = { kind = "fs_delete", path = p }
        if check(evt) then halt(evt) end
        store:remove(p)
    end
    local function copyTree(from, to, move)
        from, to = norm(from), norm(to)
        if not store:exists(from) then error("/" .. from .. ": No such file", 3) end
        if store:exists(to) then error("/" .. to .. ": File exists", 3) end
        if store.files[from] then
            store:write(to, store.files[from])
        else
            store:mkdirs(to)
            local prefix = from .. "/"
            local copies = {}
            for k, v in pairs(store.files) do
                if k:sub(1, #prefix) == prefix then copies[to .. "/" .. k:sub(#prefix + 1)] = v end
            end
            for k in pairs(store.dirs) do
                if k:sub(1, #prefix) == prefix then store:mkdirs(to .. "/" .. k:sub(#prefix + 1)) end
            end
            for k, v in pairs(copies) do store:write(k, v) end
        end
        if move then store:remove(from) end
    end
    function api.move(a, b)
        guard()
        local evt = { kind = "fs_move", from = norm(a), to = norm(b) }
        if check(evt) then halt(evt) end
        copyTree(a, b, true)
    end
    function api.copy(a, b)
        guard()
        local evt = { kind = "fs_copy", from = norm(a), to = norm(b) }
        if check(evt) then halt(evt) end
        copyTree(a, b, false)
    end
    function api.find(pattern)
        pattern = norm(pattern)
        local lp = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", "[^/]*"):gsub("%?", "[^/]") .. "$"
        local out = {}
        for k in pairs(store.files) do if k:match(lp) then out[#out + 1] = k end end
        for k in pairs(store.dirs) do if k ~= "" and k:match(lp) then out[#out + 1] = k end end
        table.sort(out)
        return out
    end
    function api.complete() return {} end

    function api.open(path, mode)
        guard()
        path = norm(path)
        mode = mode or "r"
        local m = mode:sub(1, 1)
        if m == "r" then
            local data = store.files[path]
            if not data then
                if store.dirs[path] then return nil, "/" .. path .. ": Not a file" end
                return nil, "/" .. path .. ": No such file"
            end
            local pos, closed = 1, false
            local h = {}
            local function chk() if closed then error("attempt to use a closed file", 3) end end
            function h.readLine(withTrailing)
                chk()
                if pos > #data then return nil end
                local s, e = data:find("\n", pos, true)
                local line
                if s then
                    line = withTrailing and data:sub(pos, s) or data:sub(pos, s - 1)
                    pos = s + 1
                else
                    line = data:sub(pos)
                    pos = #data + 1
                end
                if not withTrailing then line = line:gsub("\r$", "") end
                return line
            end
            function h.readAll()
                chk()
                if pos > #data then return #data == 0 and "" or nil end
                local r = data:sub(pos)
                pos = #data + 1
                return r
            end
            function h.read(n)
                chk()
                if pos > #data then return nil end
                local byteMode = mode:find("b") and n == nil
                n = n or 1
                local r = data:sub(pos, pos + n - 1)
                pos = pos + n
                if byteMode then return r:byte() end
                return r
            end
            function h.seek(whence, off)
                chk()
                whence = whence or "cur"; off = off or 0
                if whence == "set" then pos = off + 1 elseif whence == "cur" then pos = pos + off else pos = #data + off + 1 end
                return pos - 1
            end
            function h.close() chk(); closed = true end
            return h
        elseif m == "w" or m == "a" then
            if ro(path) then return nil, "/" .. path .. ": Access denied" end
            if store.dirs[path] then return nil, "/" .. path .. ": Cannot write to directory" end
            local evt = { kind = "fs_open", path = path, mode = m }
            if check(evt) then halt(evt) end
            store:mkdirs(dirname(path))
            if m == "w" or not store.files[path] then store.files[path] = "" end
            local buf, closed = {}, false
            local h = {}
            local function chk() if closed then error("attempt to use a closed file", 3) end end
            local function commit(data)
                store.files[path] = (store.files[path] or "") .. data
            end
            function h.write(s)
                chk()
                if type(s) == "number" and mode:find("b") then s = string.char(s) end
                buf[#buf + 1] = tostring(s)
            end
            function h.writeLine(s)
                chk()
                buf[#buf + 1] = tostring(s) .. "\n"
            end
            function h.flush()
                chk()
                commit(table.concat(buf))
                buf = {}
            end
            function h.close()
                chk()
                local data = table.concat(buf)
                local cevt = { kind = "fs_close", path = path, mode = m, data = data }
                if check(cevt) then
                    -- crash mid-write: only part of the data reached the disk
                    commit(data:sub(1, math.floor(#data / 2)))
                    closed = true
                    halt(cevt)
                end
                commit(data)
                buf = {}
                closed = true
            end
            return h
        end
        error("Unsupported mode: " .. tostring(mode), 2)
    end
    return api
end

return FS
