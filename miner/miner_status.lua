-- Version: 2.1.0
-- Added: Mesh network relay for extended range communication

local function createStatusModule(ctx)
    local statusLib = ctx.statusLib
    local CONFIG = ctx.CONFIG
    
    -- Relay tracking to prevent message loops
    local recentlyRelayed = {}
    local MAX_RELAY_HOPS = 3
    local RELAY_CACHE_SIZE = 50

    -- Initialize the status library once
    print("Initializing network status reporter...")
    local ok, err = pcall(statusLib.init)
    if not ok then
        print("WARNING: " .. tostring(err))
        print("Operating without network status reporting")
    end

    -- Clean old entries from relay cache
    local function cleanRelayCache()
        local cacheSize = 0
        for _ in pairs(recentlyRelayed) do
            cacheSize = cacheSize + 1
        end
        
        if cacheSize > RELAY_CACHE_SIZE then
            -- Clear half the cache (simple approach)
            local toRemove = {}
            local count = 0
            for msgId in pairs(recentlyRelayed) do
                table.insert(toRemove, msgId)
                count = count + 1
                if count > RELAY_CACHE_SIZE / 2 then
                    break
                end
            end
            for _, msgId in ipairs(toRemove) do
                recentlyRelayed[msgId] = nil
            end
        end
    end

    -- Generate unique message ID for relay tracking
    local function getMessageId(senderId, timestamp)
        return tostring(senderId) .. "_" .. tostring(timestamp)
    end

    -- Send comprehensive status update
    local function reportStatus(message)
        local statusMsg = message or ("Mining branch #" .. ctx.currentBranch)

        -- Add mining-specific data to status
        local currentStatus = statusLib.getStatus()
        currentStatus.message = statusMsg
        currentStatus.position = ctx.position
        currentStatus.oresMined = ctx.totalOresMined
        currentStatus.currentBranch = ctx.currentBranch
        currentStatus.pattern = CONFIG.MINING_PATTERN
        currentStatus.targetY = CONFIG.TARGET_Y_LEVEL
        currentStatus.currentY = ctx.position.y
        currentStatus.miningY = ctx.miningY
        currentStatus.hasGPS = ctx.hasGPS
        currentStatus.focusedOre = ctx.focusedOre
        currentStatus.relayHops = 0  -- Mark as original message
        
        -- Calculate distance from home
        local distanceHome = math.abs(ctx.position.x - ctx.homePos.x) +
                             math.abs(ctx.position.y - ctx.homePos.y) +
                             math.abs(ctx.position.z - ctx.homePos.z)
        currentStatus.distanceFromHome = distanceHome

        pcall(function()
            rednet.broadcast(currentStatus, "TURTLE_STATUS")
        end)
    end

    -- Relay a message from another turtle
    local function relayMessage(senderId, message, protocol)
        -- Don't relay our own messages
        if senderId == os.getComputerID() then
            return
        end
        
        -- Check if message has relay info
        local hops = message.relayHops or 0
        
        -- Don't relay if too many hops
        if hops >= MAX_RELAY_HOPS then
            return
        end
        
        -- Generate message ID to prevent duplicate relays
        local msgId = getMessageId(senderId, message.timestamp or os.epoch("utc"))
        
        -- Don't relay if we've already relayed this message
        if recentlyRelayed[msgId] then
            return
        end
        
        -- Mark as relayed
        recentlyRelayed[msgId] = true
        cleanRelayCache()
        
        -- Create relayed version of message
        local relayedMsg = {}
        for k, v in pairs(message) do
            relayedMsg[k] = v
        end
        relayedMsg.relayHops = hops + 1
        relayedMsg.relayedBy = os.getComputerID()
        relayedMsg.originalSender = relayedMsg.originalSender or senderId
        
        -- Broadcast the relayed message
        pcall(function()
            rednet.broadcast(relayedMsg, protocol)
        end)
    end

    -- Listen for messages to relay (runs in background)
    local function startRelayListener()
        while true do
            -- Listen for turtle status messages
            local senderId, message, protocol = rednet.receive("TURTLE_STATUS", 0.5)
            
            if senderId and message and type(message) == "table" then
                relayMessage(senderId, message, "TURTLE_STATUS")
            end
            
            -- Also relay command messages to help them reach distant turtles
            senderId, message, protocol = rednet.receive("TURTLE_COMMAND", 0.5)
            
            if senderId and message and type(message) == "table" then
                relayMessage(senderId, message, "TURTLE_COMMAND")
            end
            
            -- Small sleep to prevent tight loop
            sleep(0.1)
        end
    end

    -- Periodic status updates
    local function autoReportStatus()
        local currentTime = os.epoch("utc") / 1000
        if currentTime - ctx.lastStatusTime >= CONFIG.STATUS_INTERVAL then
            reportStatus()
            ctx.lastStatusTime = currentTime
        end
    end

    -- Network connectivity test wrapper
    local function testConnection()
        return pcall(statusLib.testConnection)
    end

    -- Report specific mining events with detailed context
    local function reportEvent(eventType, details)
        local message = eventType
        if details then
            message = message .. ": " .. details
        end
        reportStatus(message)
    end

    -- Report position change
    local function reportPositionChange()
        reportStatus(string.format("At (%d,%d,%d)", 
            ctx.position.x, ctx.position.y, ctx.position.z))
    end

    -- Report inventory status
    local function reportInventoryStatus(slotsUsed, totalSlots)
        reportStatus(string.format("Inventory: %d/%d slots", slotsUsed, totalSlots))
    end

    -- Report fuel status
    local function reportFuelStatus()
        local fuel = turtle.getFuelLevel()
        if fuel == "unlimited" then
            reportStatus("Fuel: Unlimited")
        else
            reportStatus(string.format("Fuel: %d", fuel))
        end
    end

    -- Report ore discovery
    local function reportOreDiscovered(oreName)
        ctx.totalOresMined = ctx.totalOresMined + 1
        reportStatus(string.format("Found %s! Total: %d", oreName, ctx.totalOresMined))
    end

    -- Report branch completion
    local function reportBranchComplete()
        ctx.currentBranch = ctx.currentBranch + 1
        reportStatus(string.format("Branch #%d complete", ctx.currentBranch))
    end

    -- Report descending to target depth
    local function reportDescending(targetY)
        reportStatus(string.format("Descending to Y=%d", targetY))
    end

    -- Report returning home
    local function reportReturningHome(reason)
        reportStatus("Returning home: " .. (reason or "routine"))
    end

    -- Report error condition
    local function reportError(errorMsg)
        reportStatus("ERROR: " .. errorMsg)
    end

    -- Report warning
    local function reportWarning(warningMsg)
        reportStatus("WARNING: " .. warningMsg)
    end

    return {
        report = reportStatus,
        autoReport = autoReportStatus,
        testConnection = testConnection,
        reportEvent = reportEvent,
        reportPositionChange = reportPositionChange,
        reportInventoryStatus = reportInventoryStatus,
        reportFuelStatus = reportFuelStatus,
        reportOreDiscovered = reportOreDiscovered,
        reportBranchComplete = reportBranchComplete,
        reportDescending = reportDescending,
        reportReturningHome = reportReturningHome,
        reportError = reportError,
        reportWarning = reportWarning,
        startRelayListener = startRelayListener,  -- NEW: Start relay service
    }
end

return createStatusModule