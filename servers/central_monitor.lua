-- Version: 5.0.0
-- TurtleMiner central monitor (TMINER v1): compatibility launcher. Everything moved into tminer_server.lua
-- (one program for every server PC, roles detected automatically) and its tm_*.lua modules.
-- Old startup files that run `central_monitor [monitorSide|auto|none] [textScale]` keep
-- working; `central_monitor --lib` returns the same API table as before (S, init, run,
-- handleMessage, issueCmd, newUI, render, click, navKey, ...).

local args = { ... }
local dir = ""
if shell and shell.getRunningProgram then
    local ok, p = pcall(shell.getRunningProgram)
    if ok and type(p) == "string" then
        dir = fs.getDir(p)
        if dir == ".." then dir = "" end
    end
end
local path = dir ~= "" and fs.combine(dir, "tminer_server.lua") or "tminer_server.lua"
if not fs.exists(path) then path = "tminer_server.lua" end
if not fs.exists(path) then error("tminer_server.lua is missing: run `setup server` again", 0) end
local fn, err = loadfile(path, nil, _ENV)
if not fn then error(err, 0) end
local M = fn("--lib")

if args[1] == "--lib" then return M end
M.init({ monitor = args[1], scale = tonumber(args[2]) })
M.run()
