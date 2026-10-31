-- Version: 1.0.0
-- Farmer status reporting module
-- Mirrors miner_status.lua createStatusModule pattern

local function createStatusModule(ctx)
    local statusLib = ctx.statusLib
    local CONFIG    = ctx.CONFIG

    -- Initialize network (wireless modem optional - farming works without one)
    print("Initializing farmer network reporter...")
    local hasNetwork = false
    local ok, err = pcall(statusLib.init)
    if ok then
        hasNetwork = true
        print("Network: online")
    else
        print("WARNING: " .. tostring(err))
        print("No modem - operating without network status reporting")
    end

    -- Send a full status broadcast with farming context
    local function reportStatus(message)
        local currentStatus = statusLib.getStatus()
        currentStatus.message     = message or "Farming"
        currentStatus.position    = ctx.position
        currentStatus.hasGPS      = false
        currentStatus.relayHops   = 0

        -- Farming-specific fields (displayed by central_monitor)
        currentStatus.farmCycles    = ctx.farmCycles
        currentStatus.totalHarvested = ctx.totalHarvested
        currentStatus.currentRow    = ctx.currentRow
        currentStatus.farmWidth     = CONFIG.FARM_WIDTH
        currentStatus.farmLength    = CONFIG.FARM_LENGTH
        currentStatus.cropType      = CONFIG.CROP_NAME

        -- Distance from home (Manhattan, for monitor display)
        currentStatus.distanceFromHome =
            math.abs(ctx.position.x - ctx.homePos.x) +
            math.abs(ctx.position.y - ctx.homePos.y) +
            math.abs(ctx.position.z - ctx.homePos.z)

        if hasNetwork then
            pcall(function()
                rednet.broadcast(currentStatus, "TURTLE_STATUS")
            end)
        end
    end

    -- Only broadcast when STATUS_INTERVAL has elapsed
    local function autoReport()
        local now = os.epoch("utc") / 1000
        if now - ctx.lastStatusTime >= CONFIG.STATUS_INTERVAL then
            reportStatus()
            ctx.lastStatusTime = now
        end
    end

    -- Convenience wrappers (mirrors miner_status API so monitor code is reusable)
    local function reportEvent(eventType, details)
        reportStatus(details and (eventType .. ": " .. details) or eventType)
    end

    local function reportError(msg)   reportStatus("ERROR: "   .. msg) end
    local function reportWarning(msg) reportStatus("WARNING: " .. msg) end

    local function reportHarvest(cropName, count)
        ctx.totalHarvested = ctx.totalHarvested + count
        reportStatus(string.format("Harvested %s x%d | Total: %d",
            cropName, count, ctx.totalHarvested))
    end

    local function reportRowComplete(row, total)
        reportStatus(string.format("Row %d/%d complete", row, total))
    end

    local function reportCycleComplete()
        ctx.farmCycles = ctx.farmCycles + 1
        reportStatus(string.format("Cycle #%d complete | Harvested: %d",
            ctx.farmCycles, ctx.totalHarvested))
    end

    local function reportReturningHome(reason)
        reportStatus("Returning home: " .. (reason or "routine"))
    end

    local function reportWaiting(seconds)
        reportStatus(string.format("Waiting %ds for crops to grow", seconds))
    end

    local function reportInventoryStatus(slotsUsed, totalSlots)
        reportStatus(string.format("Inventory: %d/%d slots", slotsUsed, totalSlots))
    end

    return {
        report               = reportStatus,
        autoReport           = autoReport,
        reportEvent          = reportEvent,
        reportError          = reportError,
        reportWarning        = reportWarning,
        reportHarvest        = reportHarvest,
        reportRowComplete    = reportRowComplete,
        reportCycleComplete  = reportCycleComplete,
        reportReturningHome  = reportReturningHome,
        reportWaiting        = reportWaiting,
        reportInventoryStatus = reportInventoryStatus,
    }
end

return createStatusModule
