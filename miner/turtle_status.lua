-- Version: 2.0.1
-- Fixed: Home position now includes GPS flag

local TurtleStatus = {}

local PROTOCOL = "TURTLE_STATUS"
local COMMAND_PROTOCOL = "TURTLE_COMMAND"
local POSITION_PROTOCOL = "TURTLE_POSITION"
local HEARTBEAT_INTERVAL = 5

TurtleStatus.commandQueue = {}

function TurtleStatus.init()
    local modem = peripheral.find("modem")
    if not modem then
        error("No wireless modem found! Please attach a wireless modem.")
    end
    
    rednet.open(peripheral.getName(modem))
    print("Modem opened on: " .. peripheral.getName(modem))
    
    rednet.host(COMMAND_PROTOCOL, "turtle_" .. os.getComputerID())
    rednet.host(POSITION_PROTOCOL, "turtle_pos_" .. os.getComputerID())
    
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
        return true, senderId
    else
        print("No response from central computer")
        return false, nil
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

function TurtleStatus.listenForCommands()
    while true do
        local senderId, message, protocol = rednet.receive(COMMAND_PROTOCOL, 0.1)
        
        if senderId and message and type(message) == "table" then
            print("Received command from " .. senderId .. ": " .. (message.command or "unknown"))
            
            table.insert(TurtleStatus.commandQueue, {
                sender = senderId,
                command = message.command,
                params = message.params,
                timestamp = os.epoch("utc")
            })
            
            rednet.send(senderId, {
                type = "COMMAND_ACK",
                command = message.command,
                turtleId = os.getComputerID()
            }, COMMAND_PROTOCOL)
        end
        
        sleep(0.1)
    end
end

function TurtleStatus.requestHomePosition()
    print("Requesting home position from central monitor...")
    
    local request = {
        type = "REQUEST_HOME_POSITION",
        turtleId = os.getComputerID(),
        timestamp = os.epoch("utc")
    }
    
    rednet.broadcast(request, POSITION_PROTOCOL)
    
    local senderId, response, protocol = rednet.receive(POSITION_PROTOCOL, 5)
    
    if senderId and response and response.type == "HOME_POSITION" then
        print("Received home position from central monitor")
        return response.position, response.facing
    else
        print("No home position data available")
        return nil, nil
    end
end

-- FIXED: Now accepts position table that includes hasGPS flag
function TurtleStatus.reportHomePosition(position, facing)
    print("Reporting home position to central monitor...")
    
    local report = {
        type = "SAVE_HOME_POSITION",
        turtleId = os.getComputerID(),
        position = position,  -- This now includes hasGPS field
        facing = facing,
        timestamp = os.epoch("utc")
    }
    
    rednet.broadcast(report, POSITION_PROTOCOL)
    
    local senderId, response, protocol = rednet.receive(POSITION_PROTOCOL, 3)
    
    if senderId and response and response.type == "POSITION_SAVED" then
        print("Home position saved to central monitor")
        return true
    else
        print("Warning: No acknowledgment from central monitor")
        return false
    end
end

function TurtleStatus.clearHomePosition()
    print("Clearing home position on central monitor...")
    
    local report = {
        type = "CLEAR_HOME_POSITION",
        turtleId = os.getComputerID(),
        timestamp = os.epoch("utc")
    }
    
    rednet.broadcast(report, POSITION_PROTOCOL)
    
    local senderId, response, protocol = rednet.receive(POSITION_PROTOCOL, 3)
    
    if senderId and response and response.type == "POSITION_CLEARED" then
        print("Home position cleared on central monitor")
        return true
    else
        print("Warning: No acknowledgment from central monitor")
        return false
    end
end

function TurtleStatus.getNextCommand()
    if #TurtleStatus.commandQueue > 0 then
        return table.remove(TurtleStatus.commandQueue, 1)
    end
    return nil
end

function TurtleStatus.hasPendingCommands()
    return #TurtleStatus.commandQueue > 0
end

return TurtleStatus