-- Version: 1.0.0
-- TurtleMiner server startup: runs central_monitor (UI + TMINER relay) and restarts it on crash.
-- No separate bridge is needed: central_monitor opens every modem and relays TMINER traffic.
-- Edit the CONFIG block below; nothing else needs changing.

local CONFIG = {
    monitor      = "auto",            -- monitor side/name ("right", "monitor_0"), "auto" = first found, "none" = terminal only
    textScale    = 0.5,               -- monitor text scale (0.5 .. 5)
    program      = "central_monitor", -- program to run
    restartDelay = 5,                 -- seconds to wait before restarting after a crash
}

while true do
    local ok, res = pcall(shell.run, CONFIG.program, CONFIG.monitor, tostring(CONFIG.textScale))
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
