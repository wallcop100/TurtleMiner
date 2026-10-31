-- Version: 2.1.1
-- Added: Infinite mining with automatic corridor repositioning

local function createMiningModule(ctx, status, movement, inventory)
    local CONFIG = ctx.CONFIG

    -- Check if a block is a valuable ore
    local function isValuableOre(blockData)
        if not blockData or not blockData.name then
            return false, nil
        end

        local blockName = blockData.name

        -- If focusing on specific ore, check for that
        if ctx.focusedOre and ctx.focusedOre ~= "all" then
            if blockName:find(ctx.focusedOre) then
                return true, blockName
            end
            return false, nil
        end

        -- Check against all valuable ores
        for _, ore in ipairs(CONFIG.VALUABLE_ORES) do
            if blockName == ore then
                return true, blockName
            end
        end

        return false, nil
    end

    -- Dig forward with ore detection
    local function digForward()
        local hasBlock, blockData = turtle.inspect()
        
        if hasBlock then
            local isOre, oreName = isValuableOre(blockData)
            
            if isOre then
                status.reportOreDiscovered(oreName)
                print("Ore discovered: " .. oreName)
            end
        end

        turtle.dig()
        status.autoReport()
    end

    -- Dig up with ore detection
    local function digUp()
        local hasBlock, blockData = turtle.inspectUp()
        
        if hasBlock then
            local isOre, oreName = isValuableOre(blockData)
            
            if isOre then
                status.reportOreDiscovered(oreName)
                print("Ore discovered above: " .. oreName)
            end
        end

        turtle.digUp()
        status.autoReport()
    end

    -- Dig down with ore detection
    local function digDown()
        local hasBlock, blockData = turtle.inspectDown()
        
        if hasBlock then
            local isOre, oreName = isValuableOre(blockData)
            
            if isOre then
                status.reportOreDiscovered(oreName)
                print("Ore discovered below: " .. oreName)
            end
        end

        turtle.digDown()
        status.autoReport()
    end

    -- Check and mine surrounding blocks for ores
    local function checkSurroundings()
        if not CONFIG.CHECK_SURROUNDING then
            return
        end

        -- Check up
        local hasBlock, blockData = turtle.inspectUp()
        if hasBlock then
            local isOre, oreName = isValuableOre(blockData)
            if isOre then
                status.reportEvent("Mining", oreName .. " above")
                digUp()
                movement.safeUp(digUp)
                movement.safeDown(digDown)
            end
        end

        -- Check down
        hasBlock, blockData = turtle.inspectDown()
        if hasBlock then
            local isOre, oreName = isValuableOre(blockData)
            if isOre then
                status.reportEvent("Mining", oreName .. " below")
                digDown()
                movement.safeDown(digDown)
                movement.safeUp(digUp)
            end
        end

        -- Check all 4 horizontal directions
        for i = 1, 4 do
            hasBlock, blockData = turtle.inspect()
            if hasBlock then
                local isOre, oreName = isValuableOre(blockData)
                if isOre then
                    status.reportEvent("Mining", oreName .. " ahead")
                    digForward()
                    movement.safeForward(digForward)
                    movement.back()
                end
            end
            movement.turnRight()
        end
    end

    -- Descend to target Y level
    local function descendToTarget()
        if not CONFIG.AUTO_DESCEND then
            return true
        end

        local targetY = CONFIG.TARGET_Y_LEVEL
        
        if ctx.position.y <= targetY then
            return true
        end

        status.reportDescending(targetY)
        print("Descending to Y=" .. targetY)

        while ctx.position.y > targetY do
            if not movement.safeDown(digDown) then
                status.reportError("Cannot descend further")
                return false
            end

            -- Check for ores while descending
            checkSurroundings()

            -- Check fuel - if critically low, stop completely
            local fuel = turtle.getFuelLevel()
            if fuel ~= "unlimited" then
                local distanceHome = math.abs(ctx.position.x - ctx.homePos.x) +
                                     math.abs(ctx.position.y - ctx.homePos.y) +
                                     math.abs(ctx.position.z - ctx.homePos.z)
                local fuelNeeded = distanceHome * CONFIG.FUEL_RESERVE_MULTIPLIER
                
                if fuel < fuelNeeded then
                    status.reportWarning("Low fuel during descent, returning home")
                    return false
                end
            end

            -- Check inventory
            local emptySlots = inventory.checkInventory()
            if emptySlots < 2 then
                status.reportEvent("Full inventory during descent", "pausing to dump")
                -- Save current position before going home
                local resumeY = ctx.position.y
                
                movement.returnHome()
                inventory.emptyInventory()
                
                -- Return to mining position and continue descent
                status.reportEvent("Resuming descent", "to Y=" .. targetY)
                while ctx.position.y > resumeY do
                    if not movement.safeDown(digDown) then
                        return false
                    end
                end
            end
        end

        ctx.miningY = ctx.position.y
        status.reportEvent("Reached target depth", "Y=" .. ctx.miningY)
        print("Reached target Y-level: " .. ctx.miningY)
        return true
    end

    -- Mine a single branch
    function runMineBranch(length)

        local result = nil

        -- === MINING TASK ===
        local function miningTask()

            status.reportEvent("Mining branch", "#" .. (ctx.currentBranch + 1))
            print("Mining branch #" .. (ctx.currentBranch + 1) .. " (length: " .. length .. ")")

            for i = 1, length do

                -- Dig forward and move
                if not movement.safeForward(digForward) then
                    status.reportError("Stuck while mining branch")
                    result = "STUCK"
                    return
                end

                -- Check surroundings for ores
                checkSurroundings()

                -- Status update every 5 blocks
                if i % 5 == 0 then
                    status.reportEvent("Mining", string.format("Block %d/%d", i, length))
                end

                -- ===== FUEL CHECK =====
                local fuel = turtle.getFuelLevel()
                if fuel ~= "unlimited" then
                    local distanceHome =
                        math.abs(ctx.position.x - ctx.homePos.x) +
                        math.abs(ctx.position.y - ctx.homePos.y) +
                        math.abs(ctx.position.z - ctx.homePos.z)

                    local fuelNeeded = distanceHome * CONFIG.FUEL_RESERVE_MULTIPLIER

                    if fuel < fuelNeeded then
                        status.reportWarning("CRITICAL: Low fuel during branch")
                        print("CRITICAL LOW FUEL - must return home NOW")
                        result = "CRITICAL_FUEL"
                        return
                    end
                end

                -- ===== INVENTORY CHECK =====
                local emptySlots = inventory.checkInventory()
                if emptySlots < 2 then
                    status.reportEvent("Inventory full", "pausing to dump")
                    print("Inventory full - returning to dump")
                    result = "INVENTORY_FULL"
                    return
                end
            end

            status.reportBranchComplete()
            result = "COMPLETE"
        end


        -- === REMOTE LISTENER ===
        local function remoteListener()
            while true do
                local senderId, message = rednet.receive()

                if message == "RETURN_HOME" then
                    print("Remote RETURN_HOME command received")
                    error("REMOTE_INTERRUPT")
                end
            end
        end


        -- === RUN IN PARALLEL ===
        local ok, err = pcall(function()
            parallel.waitForAny(miningTask, remoteListener)
        end)

        -- If interrupted remotely
        if not ok and err == "REMOTE_INTERRUPT" then
            print("Mining interrupted by remote command")
            return "COMMAND_STOP"
        end

        return result
    end

    -- Navigate back from a branch to the main corridor
    local function returnToCorridorStart(branchLength)
        status.reportEvent("Returning", "to corridor")
        print("Returning to corridor start...")
        
        movement.turnAround()
        for i = 1, branchLength do
            if not movement.safeForward() then
                status.reportWarning("Stuck returning to corridor")
                return false
            end
        end
        movement.turnAround()
        return true
    end

    -- Move to next branch position
    local function moveToNextBranch()
        status.reportEvent("Positioning", "for next branch")
        print("Moving to next branch position...")
        
        movement.turnRight()
        for i = 1, CONFIG.BRANCH_SPACING do
            if not movement.safeForward(digForward) then
                status.reportWarning("Cannot position for next branch - corridor blocked")
                print("Cannot move to next branch position")
                movement.turnLeft()
                return false
            end
        end
        movement.turnLeft()
        return true
    end

    -- Move to a new corridor position
    local function moveToNewCorridor()
        status.reportEvent("Corridor exhausted", "moving to new area")
        print("Current corridor exhausted - moving to new corridor...")
        
        -- Return to surface
        movement.returnHome()
        inventory.emptyInventory()
        
        -- Move to a new position (shift perpendicular to current corridor)
        status.reportEvent("Repositioning", "finding new corridor")
        print("Shifting to new corridor position...")
        
        -- Turn perpendicular and move forward by corridor spacing
        movement.turnRight()
        for i = 1, CONFIG.BRANCH_SPACING * 2 do
            if not movement.safeForward(digForward) then
                status.reportWarning("Cannot shift to new corridor position")
                return false
            end
        end
        movement.turnLeft()
        
        print("New corridor position established")
        return true
    end

    -- Main mining loop
    local function mine()
        status.report("Mining started")
        print("Starting mining operation...")

        -- INFINITE MINING LOOP
        while true do
            -- Check for stop command
            if ctx.shouldReturnHome then
                print("Stop command received - ending operation")
                status.reportEvent("Stop command", "mining halted")
                break
            end

            -- Descend to target depth
            if not descendToTarget() then
                status.reportError("Failed to reach target depth")
                movement.returnHome()
                inventory.emptyInventory()
                return
            end

            -- Branch mining pattern
            if CONFIG.MINING_PATTERN == "branch" then
                local corridorActive = true
                local branchesInCorridor = 0
                
                while corridorActive do
                    -- Check for stop command
                    if ctx.shouldReturnHome then
                        print("Stop command received - returning home")
                        status.reportEvent("Stop command", "mining halted")
                        corridorActive = false
                        break
                    end

                    -- Mine a branch
                    local result = mineBranch(CONFIG.BRANCH_LENGTH)
                    
                    if result == "COMPLETE" then
                        -- Branch completed successfully
                        branchesInCorridor = branchesInCorridor + 1
                        
                        if not returnToCorridorStart(CONFIG.BRANCH_LENGTH) then
                            status.reportWarning("Cannot return to corridor - ending this corridor")
                            corridorActive = false
                            break
                        end
                        
                        if not moveToNextBranch() then
                            -- Can't move to next branch - corridor exhausted
                            print("Corridor exhausted after " .. branchesInCorridor .. " branches")
                            status.reportEvent("Corridor complete", branchesInCorridor .. " branches mined")
                            corridorActive = false
                            break
                        end
                        
                    elseif result == "INVENTORY_FULL" then
                        -- Inventory full - return home, dump, and CONTINUE mining
                        print("Inventory full - dumping and resuming")
                        status.reportEvent("Inventory full", "returning to dump")
                        
                        movement.returnHome()
                        inventory.emptyInventory()
                        
                        -- Check fuel after returning
                        local fuel = turtle.getFuelLevel()
                        if fuel ~= "unlimited" then
                            local distanceHome = math.abs(ctx.position.x - ctx.homePos.x) +
                                                math.abs(ctx.position.y - ctx.homePos.y) +
                                                math.abs(ctx.position.z - ctx.homePos.z)
                            local fuelNeeded = distanceHome * CONFIG.FUEL_RESERVE_MULTIPLIER * 2
                            
                            if fuel < fuelNeeded then
                                print("Not enough fuel to continue mining")
                                status.reportWarning("Insufficient fuel to resume")
                                corridorActive = false
                                break
                            end
                        end
                        
                        -- Descend back to mining level
                        status.reportEvent("Resuming", "returning to mining depth")
                        if not descendToTarget() then
                            corridorActive = false
                            break
                        end
                        
                        -- Continue from where we left off (branch will resume at corridor position)
                        
                    elseif result == "CRITICAL_FUEL" then
                        -- Critical low fuel - MUST return home NOW
                        print("CRITICAL LOW FUEL - ending mining operation")
                        status.reportWarning("Critical fuel level - ending operation")
                        corridorActive = false
                        break
                        
                    elseif result == "COMMAND_STOP" then
                        -- Remote stop command
                        print("Remote stop command - ending mining")
                        corridorActive = false
                        break
                        
                    else
                        -- Error (STUCK, etc) - end this corridor
                        print("Error during mining - ending this corridor")
                        status.reportWarning("Error encountered - moving to new corridor")
                        corridorActive = false
                        break
                    end

                    -- Periodic fuel check between branches
                    local fuel = turtle.getFuelLevel()
                    if fuel ~= "unlimited" then
                        local distanceHome = math.abs(ctx.position.x - ctx.homePos.x) +
                                            math.abs(ctx.position.y - ctx.homePos.y) +
                                            math.abs(ctx.position.z - ctx.homePos.z)
                        local fuelNeeded = distanceHome * CONFIG.FUEL_RESERVE_MULTIPLIER
                        
                        if fuel < fuelNeeded then
                            print("Low fuel detected - ending this corridor")
                            status.reportWarning("Low fuel - moving to new corridor")
                            corridorActive = false
                            break
                        end
                    end
                end
                
                -- Corridor exhausted or error - move to new corridor
                if ctx.shouldReturnHome then
                    -- Stop command received
                    break
                end
                
                if not moveToNewCorridor() then
                    status.reportError("Cannot establish new corridor")
                    break
                end
                
                print("Starting new corridor...")
                status.reportEvent("New corridor", "starting fresh branches")
            end
        end

        -- Final return home
        status.reportReturningHome("mining stopped")
        print("Mining operation stopped, returning home...")
        movement.returnHome()
        inventory.emptyInventory()
    end

    return {
        mine = mine,
        digForward = digForward,
        digUp = digUp,
        digDown = digDown,
        checkSurroundings = checkSurroundings,
    }
end

return createMiningModule