local WIRELESS = "top"
local WIRED = "back"
local MONITOR = "top"

local function run_monitor()
  local mon = peripheral.wrap(MONITOR)
  mon.setTextScale(0.5)
  term.redirect(mon)
  shell.run("central_monitor")
end

parallel.waitForAny(run_monitor)
