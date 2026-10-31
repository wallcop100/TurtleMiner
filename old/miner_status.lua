-- Version: 1.1.1
-- Mining status & network reporting for TurtleMiner
-- Responsible for initializing the status library and broadcasting updates.

local function createStatusModule(ctx)
    local statusLib = ctx.statusLib
    local CONFIG = ctx.CONFIG

    -- Initialize the status library once
    print("Initializing network status reporter...")
    local ok, err = pcall(statusLib.init)
    if not ok then
        print("WARNING: " .. tostring(err))
        print("Operating without network status reporting")
    end

    -- Send status update with mining info
    local function reportStatus(message)
        local statusMsg = message or ("Mining branch #" .. ctx.currentBranch)

        -- Add mining-specific data to status
        local currentStatus = statusLib.getStatus()
        currentStatus.message = statusMsg
        currentStatus.position = ctx.position
        currentStatus.oresMined = ctx.totalOresMined
        currentStatus.currentBranch = ctx.currentBranch
        currentStatus.pattern = CONFIG.MINING_PATTERN

        pcall(function()
            rednet.broadcast(currentStatus, "TURTLE_STATUS")
        end)
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

    return {
        report = reportStatus,
        autoReport = autoReportStatus,
        testConnection = testConnection,
    }
end

return createStatusModule

