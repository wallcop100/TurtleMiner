local WIRELESS = "top"
local WIRED = "back"
local MONITOR = "right"

local w = peripheral.wrap(WIRELESS)
local c = peripheral.wrap(WIRED)

local openW, openC = {}, {}

local function ensureOpen(modem, openTable, ch)
  if not openTable[ch] then
    modem.open(ch)
    openTable[ch] = true
  end
end

local function rednet_bridge()
  print("Rednet bridge running")
  while true do
    local _, side, ch, replyCh, msg = os.pullEvent("modem_message")

    if side == WIRELESS then
      ensureOpen(c, openC, ch)
      ensureOpen(c, openC, replyCh)
      c.transmit(ch, replyCh, msg)

    elseif side == WIRED then
      ensureOpen(w, openW, ch)
      ensureOpen(w, openW, replyCh)
      w.transmit(ch, replyCh, msg)
    end
  end
end

local function run_monitor()
  local mon = peripheral.wrap(MONITOR)
  mon.setTextScale(0.5)
  term.redirect(mon)
  shell.run("central_monitor")
end

parallel.waitForAny(rednet_bridge, run_monitor)
