-- Version: 1.0.0
-- TurtleMiner relay startup: runs relay.lua and restarts it if it stops. Setup writes
-- startup.lua = shell.run("relay_startup").
-- Update probation (tmguard.lua): an interrupted install is finished first; a crash right
-- after an update puts the previous files back and reboots.

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
    local ok, err
    if guard then ok, err = pcall(guard.run, "relay") else ok, err = pcall(shell.run, "relay") end
    print("relay stopped: " .. tostring(err))
    sleep(5)
end
