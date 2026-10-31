-- Version: 1.0.1
-- Enhanced Turtle Status Reporter with Command Receiving

local TurtleStatus = {}

local PROTOCOL = "TURTLE_STATUS"
local COMMAND_PROTOCOL = "TURTLE_COMMAND"
local HEARTBEAT_INTERVAL = 5

function TurtleStatus.init()
    local modem = peripheral.find("modem")
    if not modem then
        error("No wireless modem found! Please attach a wireless modem.")
    end
    
    rednet.open(peripheral.getName(modem))
    print("Modem opened on: " .. peripheral.getName(modem))
    
    -- Open command protocol for receiving
    rednet.host(COMMAND_PROTOCOL, "turtle_" .. os.getComputerID())
    
    return true
end

function TurtleStatus.getStatus()
    local status = {
        id = os.getComputerID(),
        label = os.getComputerLabel() or "Turtle-" .. os.getComputerID(),
        fuel = turtle.getFuelLevel(),
        position = {x = 0, y = 0, z = 0},
        timestamp = os.epoch("utc"),
        inventory = {}
    }
    
    local itemCount = 0
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
            itemCount = itemCount + 1
        end
    end
    status.inventory.slotsUsed = itemCount
    
    return status
end

function TurtleStatus.sendStatus(message)
    local status = TurtleStatus.getStatus()
    if message then
        status.message = message
    end
    
    local success, err = pcall(function()
        rednet.broadcast(status, PROTOCOL)
    end)
    
    if not success then
        print("Error sending status: " .. tostring(err))
        return false, err
    end
    
    return true
end

function TurtleStatus.testConnection()
    print("Testing connection...")
    
    local testMsg = {
        id = os.getComputerID(),
        type = "TEST",
        timestamp = os.epoch("utc")
    }
    
    rednet.broadcast(testMsg, PROTOCOL)
    print("Test message sent!")
    
    local senderId, message, protocol = rednet.receive(PROTOCOL, 3)
    
    if senderId and message and message.type == "ACK" then
        print("Connection OK! Central computer ID: " .. senderId)
        return true
    else
        print("No response from central computer")
        return false
    end
end

function TurtleStatus.startHeartbeat(interval)
    interval = interval or HEARTBEAT_INTERVAL
    
    while true do
        local success, err = TurtleStatus.sendStatus("Heartbeat")
        if not success then
            print("Heartbeat failed: " .. tostring(err))
        end
        sleep(interval)
    end
end

return TurtleStatus