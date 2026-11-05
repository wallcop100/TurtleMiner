-- Version: 1.0.0
-- Update server startup: runs update_server and restarts it if it crashes.
-- Quit with Q inside the server (clean exit), or Ctrl+T during the restart wait.

while true do
    local ok = shell.run("update_server")
    if ok then break end
    printError("update_server stopped with an error; restarting in 5 s (Ctrl+T to cancel)")
    sleep(5)
end
