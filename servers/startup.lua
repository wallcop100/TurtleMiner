-- Version: 3.0.0
-- TurtleMiner server startup: runs tminer_server (every role this PC has: UI, radio gateway,
-- cluster link, update server) and restarts it on crash. Same file on every server PC.
-- Edit the CONFIG block below; nothing else needs changing.
-- Update probation (tmguard.lua, docs/MESH_UPDATE_PLAN.md section 3): an interrupted install
-- is finished first; a crash right after an update puts the previous files back and reboots.

local CONFIG = {
    monitor      = "auto",            -- monitor side/name ("right", "monitor_0"), "auto" = first found, "none" = terminal only
    textScale    = 0.5,               -- monitor text scale (0.5 .. 5)
    program      = "tminer_server",   -- program to run
    restartDelay = 5,                 -- seconds to wait before restarting after a crash
}

local guard = nil
do
    local fn = fs.exists("tmguard.lua") and loadfile("tmguard.lua", nil, _ENV)
    local ok, g = pcall(fn or error)
    if ok and type(g) == "table" then guard = g end
end
if guard then
    local ok, err = pcall(guard.boot)
    if not ok then print("[update] guard: " .. tostring(err)) end
end

while true do
    local ok, res
    if guard then
        ok, res = pcall(guard.run, CONFIG.program, CONFIG.monitor, tostring(CONFIG.textScale))
    else
        ok, res = pcall(shell.run, CONFIG.program, CONFIG.monitor, tostring(CONFIG.textScale))
    end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    if ok then
        print(CONFIG.program .. (res and " exited" or " crashed"))
    else
        print(CONFIG.program .. " crashed: " .. tostring(res))
    end
    term.setTextColor(colors.white)
    print("Restarting in " .. CONFIG.restartDelay .. "s (Ctrl+T now to stop)")
    sleep(CONFIG.restartDelay)
end
