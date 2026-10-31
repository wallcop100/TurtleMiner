-- Version: 2.0.1
-- Enhanced Movement with Detailed Status Reporting

local function createMovementModule(ctx, status)
    local CONFIG = ctx.CONFIG

    -- Notify listeners when position changes
    local function positionChanged()
        if ctx.onPositionChanged then
            ctx.onPositionChanged(ctx.position.x, ctx.position.y, ctx.position.z)
        end
    end

    -- Basic movement with position tracking
    local function forward()
        local success, reason = turtle.forward()
        if success then
            if ctx.facing == 0 then
                ctx.position.z = ctx.position.z - 1
            elseif ctx.facing == 1 then
                ctx.position.x = ctx.position.x + 1
            elseif ctx.facing == 2 then
                ctx.position.z = ctx.position.z + 1
            elseif ctx.facing == 3 then
                ctx.position.x = ctx.position.x - 1
            end
            status.autoReport()
            positionChanged()
        end
        return success, reason
    end

    local function back()
        local success = turtle.back()
        if success then
            if ctx.facing == 0 then
                ctx.position.z = ctx.position.z + 1
            elseif ctx.facing == 1 then
                ctx.position.x = ctx.position.x - 1
            elseif ctx.facing == 2 then
                ctx.position.z = ctx.position.z - 1
            elseif ctx.facing == 3 then
                ctx.position.x = ctx.position.x + 1
            end
            status.autoReport()
            positionChanged()
        end
        return success
    end

    local function up()
        local success = turtle.up()
        if success then
            ctx.position.y = ctx.position.y + 1
            status.autoReport()
            positionChanged()
        end
        return success
    end

    local function down()
        local success = turtle.down()
        if success then
            ctx.position.y = ctx.position.y - 1
            status.autoReport()
            positionChanged()
        end
        return success
    end

    local function turnRight()
        turtle.turnRight()
        ctx.facing = (ctx.facing + 1) % 4
    end

    local function turnLeft()
        turtle.turnLeft()
        ctx.facing = (ctx.facing - 1) % 4
    end

    local function turnAround()
        turnRight()
        turnRight()
    end

    -- Safe movement helpers with enhanced status reporting
    local function safeForward(digForwardFn)
        local attempts = 0
        while not forward() do
            attempts = attempts + 1
            if attempts > CONFIG.MAX_STUCK_ATTEMPTS then
                status.reportError("Stuck forward after " .. attempts .. " attempts")
                return false
            end

            if attempts == 1 then
                status.reportEvent("Obstacle", "clearing forward")
            end

            if digForwardFn then
                digForwardFn()
            else
                turtle.dig()
            end
            turtle.attack()
            sleep(0.5)
        end
        
        if attempts > 0 then
            status.reportEvent("Cleared", attempts .. " obstacles forward")
        end
        
        return true
    end

    local function safeUp(digUpFn)
        local attempts = 0
        while not up() do
            attempts = attempts + 1
            if attempts > CONFIG.MAX_STUCK_ATTEMPTS then
                status.reportError("Stuck up after " .. attempts .. " attempts")
                return false
            end

            if attempts == 1 then
                status.reportEvent("Obstacle", "clearing above")
            end

            if digUpFn then
                digUpFn()
            else
                turtle.digUp()
            end
            turtle.attackUp()
            sleep(0.5)
        end
        
        if attempts > 0 then
            status.reportEvent("Cleared", attempts .. " obstacles above")
        end
        
        return true
    end

    local function safeDown(digDownFn)
        local attempts = 0
        while not down() do
            attempts = attempts + 1
            if attempts > CONFIG.MAX_STUCK_ATTEMPTS then
                status.reportError("Stuck down after " .. attempts .. " attempts")
                return false
            end

            if attempts == 1 then
                status.reportEvent("Obstacle", "clearing below")
            end

            if digDownFn then
                digDownFn()
            else
                turtle.digDown()
            end
            turtle.attackDown()
            sleep(0.5)
        end
        
        if attempts > 0 then
            status.reportEvent("Cleared", attempts .. " obstacles below")
        end
        
        return true
    end

    -- Return to home position with progress updates
    local function returnHome()
        local distance = math.abs(ctx.position.x - ctx.homePos.x) +
                         math.abs(ctx.position.y - ctx.homePos.y) +
                         math.abs(ctx.position.z - ctx.homePos.z)

        status.reportReturningHome("distance: " .. distance)
        print("Returning to home position...")
        print("Distance: " .. distance .. " blocks")

        local startDistance = distance
        local lastReportedPercent = 0

        local function reportProgress()
            local currentDistance = math.abs(ctx.position.x - ctx.homePos.x) +
                                   math.abs(ctx.position.y - ctx.homePos.y) +
                                   math.abs(ctx.position.z - ctx.homePos.z)
            local percent = math.floor(((startDistance - currentDistance) / startDistance) * 100)
            
            if percent >= lastReportedPercent + 25 then
                status.reportEvent("Return progress", percent .. "% complete")
                lastReportedPercent = percent
            end
        end


        -- Return to X position
        if ctx.position.x ~= ctx.homePos.x then
            status.reportEvent("Navigating X", "to home position")
        end
        
        while ctx.position.x < ctx.homePos.x do
            while ctx.facing ~= 1 do
                turnRight()
            end
            if not safeForward() then
                status.reportError("Cannot move to home X")
                return false
            end
            reportProgress()
        end
        while ctx.position.x > ctx.homePos.x do
            while ctx.facing ~= 3 do
                turnRight()
            end
            if not safeForward() then
                status.reportError("Cannot move to home X")
                return false
            end
            reportProgress()
        end

        -- Return to Z position
        if ctx.position.z ~= ctx.homePos.z then
            status.reportEvent("Navigating Z", "to home position")
        end
        
        while ctx.position.z < ctx.homePos.z do
            while ctx.facing ~= 2 do
                turnRight()
            end
            if not safeForward() then
                status.reportError("Cannot move to home Z")
                return false
            end
            reportProgress()
        end
        while ctx.position.z > ctx.homePos.z do
            while ctx.facing ~= 0 do
                turnRight()
            end
            if not safeForward() then
                status.reportError("Cannot move to home Z")
                return false
            end
            reportProgress()
        end
        -- Return to starting height first (safer)
        if ctx.position.y < ctx.homePos.y then
            status.reportEvent("Ascending", "to home Y-level")
        elseif ctx.position.y > ctx.homePos.y then
            status.reportEvent("Descending", "to home Y-level")
        end

        while ctx.position.y < ctx.homePos.y do
            if not safeUp() then
                status.reportError("Cannot ascend to home Y")
                return false
            end
            reportProgress()
        end
        while ctx.position.y > ctx.homePos.y do
            if not safeDown() then
                status.reportError("Cannot descend to home Y")
                return false
            end
            reportProgress()
        end

        -- Face original direction (north)
        while ctx.facing ~= 0 do
            turnRight()
        end

        status.reportEvent("Arrived", "at home base")
        print("Arrived at home position")
        return true
    end

    return {
        forward = forward,
        back = back,
        up = up,
        down = down,
        turnRight = turnRight,
        turnLeft = turnLeft,
        turnAround = turnAround,
        safeForward = safeForward,
        safeUp = safeUp,
        safeDown = safeDown,
        returnHome = returnHome,
    }
end

return createMovementModule