-- Simple listener to verify mined-DB packets are received.
-- Run on the central computer (or any computer) with a wireless modem.

local MINED_PROTOCOL = "TURTLE_MINED_DB"

local function initModem()
  local modem = peripheral.find("modem")
  if not modem then
    error("No wireless modem found! Please attach a wireless modem.")
  end
  rednet.open(peripheral.getName(modem))
  print("Modem opened on: " .. peripheral.getName(modem))
end

initModem()

print("Listening on protocol: " .. MINED_PROTOCOL)
print("Computer ID: " .. os.getComputerID())
print("Press Ctrl+T to stop.")
print("")

local count = 0
while true do
  local senderId, message, protocol = rednet.receive(MINED_PROTOCOL)
  if senderId and protocol == MINED_PROTOCOL then
    count = count + 1
    local msgType = type(message) == "table" and tostring(message.type) or tostring(type(message))
    print(string.format("[%d] from %s type=%s", count, tostring(senderId), msgType))
    if type(message) == "table" then
      print(textutils.serialize(message))
    else
      print(tostring(message))
    end
    print("")
  end
end

