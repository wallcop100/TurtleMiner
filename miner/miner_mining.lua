-- Version: 2.4.1
-- Fixed: Vein mining now properly mines ALL surrounding ore blocks recursively

local function createMiningModule(ctx, status, movement, inventory)
    local CONFIG = ctx.CONFIG

    -- Track vein mining state
    local veinMiningActive = false
    local veinStartPos = nil
    local veinStartFacing = nil
    local minedBlocks = {}  -- Track visited positions to avoid loops

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

    -- Clear mined blocks tracking
    local function clearMinedTracking()
        minedBlocks = {}
    end

    -- Calculate distance between two positions
    local function distance(x1, y1, z1, x2, y2, z2)
        return math.abs(x1 - x2) + math.abs(y1 - y2) + math.abs(z1 - z2)
    end

    -- Navigate back to a specific position
    local function navigateToPosition(targetX, targetY, targetZ, targetFacing)
        status.reportEvent("Vein complete", "returning to path")
        print("Returning to path position...")

        local attempts = 0
        local maxAttempts = 100

        -- Move to target position
        while (ctx.position.x ~= targetX or ctx.position.y ~= targetY or ctx.position.z ~= targetZ) and attempts < maxAttempts do
            attempts = attempts + 1

            -- Check for interrupt
            if ctx.commandInterrupt then
                return false
            end

            -- Move X/Z first so we follow existing tunnels, then adjust Y last.
            -- Moving Y first would bring the turtle to surface level and cause it
            -- to dig through unrelated terrain instead of retracing its path.
            if ctx.position.x < targetX then
                while ctx.facing ~= 1 do movement.turnRight() end
                if not movement.safeForward() then
                    return false
                end
            elseif ctx.position.x > targetX then
                while ctx.facing ~= 3 do movement.turnRight() end
                if not movement.safeForward() then
                    return false
                end
            elseif ctx.position.z < targetZ then
                while ctx.facing ~= 2 do movement.turnRight() end
                if not movement.safeForward() then
                    return false
                end
            elseif ctx.position.z > targetZ then
                while ctx.facing ~= 0 do movement.turnRight() end
                if not movement.safeForward() then
                    return false
                end
            -- Only move vertically once we are in the right X/Z column
            elseif ctx.position.y < targetY then
                if not movement.safeUp() then
                    return false
                end
            elseif ctx.position.y > targetY then
                if not movement.safeDown() then
                    return false
                end
            end

            -- Progress indicator every 10 moves
            if attempts % 10 == 0 then
                local dist = distance(ctx.position.x, ctx.position.y, ctx.position.z, targetX, targetY, targetZ)
                status.reportEvent("Navigating back", dist .. " blocks away")
            end
        end

        if attempts >= maxAttempts then
            status.reportError("Could not return to path - navigation timeout")
            return false
        end

        -- Restore facing direction
        while ctx.facing ~= targetFacing do
            movement.turnRight()
        end

        status.reportEvent("Returned", "resumed mining path")
        return true
    end

    -- Navigate to a target X/Z position at the current Y level (surface-safe navigation)
    local function navigateToXZ(targetX, targetZ)
        while ctx.position.x < targetX do
            while ctx.facing ~= 1 do movement.turnRight() end
            if not movement.safeForward(digForward) then return false end
        end
        while ctx.position.x > targetX do
            while ctx.facing ~= 3 do movement.turnRight() end
            if not movement.safeForward(digForward) then return false end
        end
        while ctx.position.z < targetZ do
            while ctx.facing ~= 2 do movement.turnRight() end
            if not movement.safeForward(digForward) then return false end
        end
        while ctx.position.z > targetZ do
            while ctx.facing ~= 0 do movement.turnRight() end
            if not movement.safeForward(digForward) then return false end
        end
        return true
    end

    -- Mine an ore vein recursively - AGGRESSIVE VERSION
    local function mineVeinRecursive(oreName, depth)
        depth = depth or 0

        -- Safety limits
        if depth > 100 then
            status.reportWarning("Vein depth limit reached (100 blocks)")
            return
        end

        -- Check for interrupt
        if ctx.commandInterrupt then
            return
        end

        -- Check inventory space
        local emptySlots = inventory.checkInventory()
        if emptySlots < 2 then
            status.reportEvent("Vein mining", "inventory full - stopping")
            return
        end

        -- Get current position key
        local posKey = ctx.position.x .. "," .. ctx.position.y .. "," .. ctx.position.z
        
        -- Mark current position as visited
        minedBlocks[posKey] = true

        -- Check all 6 directions and mine any matching ore
        local foundOre = false

        -- Check UP
        local hasBlock, blockData = turtle.inspectUp()
        if hasBlock and blockData and blockData.name == oreName then
            local upKey = ctx.position.x .. "," .. (ctx.position.y + 1) .. "," .. ctx.position.z
            if not minedBlocks[upKey] then
                foundOre = true
                turtle.digUp()
                status.reportEvent("Vein mining", oreName .. " (up)")
                
                if movement.up() then
                    mineVeinRecursive(oreName, depth + 1)
                    movement.down()
                end
            end
        end

        -- Check DOWN
        hasBlock, blockData = turtle.inspectDown()
        if hasBlock and blockData and blockData.name == oreName then
            local downKey = ctx.position.x .. "," .. (ctx.position.y - 1) .. "," .. ctx.position.z
            if not minedBlocks[downKey] then
                foundOre = true
                turtle.digDown()
                status.reportEvent("Vein mining", oreName .. " (down)")
                
                if movement.down() then
                    mineVeinRecursive(oreName, depth + 1)
                    movement.up()
                end
            end
        end

        -- Check all 4 HORIZONTAL directions (forward, right, back, left)
        for i = 1, 4 do
            hasBlock, blockData = turtle.inspect()
            if hasBlock and blockData and blockData.name == oreName then
                -- Calculate what position this would be
                local checkX, checkZ = ctx.position.x, ctx.position.z
                if ctx.facing == 0 then      -- North
                    checkZ = checkZ - 1
                elseif ctx.facing == 1 then  -- East
                    checkX = checkX + 1
                elseif ctx.facing == 2 then  -- South
                    checkZ = checkZ + 1
                elseif ctx.facing == 3 then  -- West
                    checkX = checkX - 1
                end
                
                local forwardKey = checkX .. "," .. ctx.position.y .. "," .. checkZ
                
                if not minedBlocks[forwardKey] then
                    foundOre = true
                    turtle.dig()
                    status.reportEvent("Vein mining", oreName .. " (horizontal)")
                    
                    if movement.forward() then
                        mineVeinRecursive(oreName, depth + 1)
                        movement.back()
                    end
                end
            end
            
            -- Turn to check next direction
            movement.turnRight()
        end

        if foundOre and depth % 5 == 0 then
            print("Vein mining: depth " .. depth .. " blocks...")
        end
    end

    -- Dig forward with ore detection and vein mining
    local function digForward()
        -- Check for interrupt before each action
        if ctx.commandInterrupt then
            return false
        end
        
        local hasBlock, blockData = turtle.inspect()
        
        if hasBlock then
            local isOre, oreName = isValuableOre(blockData)
            
            if isOre then
                status.reportOreDiscovered(oreName)
                print("Ore discovered: " .. oreName)
                
                -- Start vein mining if enabled
                if CONFIG.MINE_ENTIRE_VEINS and not veinMiningActive then
                    -- Save CURRENT position to return to after vein mining
                    veinMiningActive = true
                    veinStartPos = {x = ctx.position.x, y = ctx.position.y, z = ctx.position.z}
                    veinStartFacing = ctx.facing
                    clearMinedTracking()
                    
                    status.reportEvent("Vein found", "mining " .. oreName)
                    print("Found " .. oreName .. " vein! Mining completely...")
                    
                    -- Dig the ore block
                    turtle.dig()
                    status.autoReport()
                    
                    -- Move INTO the ore's position to start vein mining from inside
                    if movement.forward() then
                        local blocksMinedBefore = 0
                        for _ in pairs(minedBlocks) do
                            blocksMinedBefore = blocksMinedBefore + 1
                        end
                        
                        -- Now mine everything around us recursively
                        mineVeinRecursive(oreName, 0)
                        
                        local blocksMinedAfter = 0
                        for _ in pairs(minedBlocks) do
                            blocksMinedAfter = blocksMinedAfter + 1
                        end
                        
                        local totalMined = blocksMinedAfter - blocksMinedBefore
                        print("Vein complete: mined " .. totalMined .. " ore blocks")
                        status.reportEvent("Vein complete", totalMined .. " blocks mined")
                        
                        -- Return to ORIGINAL position (before we moved forward)
                        navigateToPosition(veinStartPos.x, veinStartPos.y, veinStartPos.z, veinStartFacing)
                    end
                    
                    veinMiningActive = false
                    clearMinedTracking()
                else
                    -- Just dig normally if vein mining disabled or already active
                    turtle.dig()
                    status.autoReport()
                end
                
                return true
            end
        end

        turtle.dig()
        status.autoReport()
        return true
    end

    -- Dig up with ore detection and vein mining
    local function digUp()
        -- Check for interrupt
        if ctx.commandInterrupt then
            return false
        end
        
        local hasBlock, blockData = turtle.inspectUp()
        
        if hasBlock then
            local isOre, oreName = isValuableOre(blockData)
            
            if isOre then
                status.reportOreDiscovered(oreName)
                print("Ore discovered above: " .. oreName)
                
                -- Start vein mining if enabled
                if CONFIG.MINE_ENTIRE_VEINS and not veinMiningActive then
                    -- Save CURRENT position
                    veinMiningActive = true
                    veinStartPos = {x = ctx.position.x, y = ctx.position.y, z = ctx.position.z}
                    veinStartFacing = ctx.facing
                    clearMinedTracking()
                    
                    status.reportEvent("Vein found", "mining " .. oreName)
                    print("Found " .. oreName .. " vein! Mining completely...")
                    
                    -- Dig the ore block
                    turtle.digUp()
                    status.autoReport()
                    
                    -- Move INTO the ore's position
                    if movement.up() then
                        local blocksMinedBefore = 0
                        for _ in pairs(minedBlocks) do
                            blocksMinedBefore = blocksMinedBefore + 1
                        end
                        
                        -- Mine the vein from inside
                        mineVeinRecursive(oreName, 0)
                        
                        local blocksMinedAfter = 0
                        for _ in pairs(minedBlocks) do
                            blocksMinedAfter = blocksMinedAfter + 1
                        end
                        
                        local totalMined = blocksMinedAfter - blocksMinedBefore
                        print("Vein complete: mined " .. totalMined .. " ore blocks")
                        status.reportEvent("Vein complete", totalMined .. " blocks mined")
                        
                        -- Return to original position
                        navigateToPosition(veinStartPos.x, veinStartPos.y, veinStartPos.z, veinStartFacing)
                    end
                    
                    veinMiningActive = false
                    clearMinedTracking()
                else
                    -- Just dig normally
                    turtle.digUp()
                    status.autoReport()
                end
                
                return true
            end
        end

        turtle.digUp()
        status.autoReport()
        return true
    end

    -- Dig down with ore detection and vein mining
    local function digDown()
        -- Check for interrupt
        if ctx.commandInterrupt then
            return false
        end
        
        local hasBlock, blockData = turtle.inspectDown()
        
        if hasBlock then
            local isOre, oreName = isValuableOre(blockData)
            
            if isOre then
                status.reportOreDiscovered(oreName)
                print("Ore discovered below: " .. oreName)
                
                -- Start vein mining if enabled
                if CONFIG.MINE_ENTIRE_VEINS and not veinMiningActive then
                    -- Save CURRENT position
                    veinMiningActive = true
                    veinStartPos = {x = ctx.position.x, y = ctx.position.y, z = ctx.position.z}
                    veinStartFacing = ctx.facing
                    clearMinedTracking()
                    
                    status.reportEvent("Vein found", "mining " .. oreName)
                    print("Found " .. oreName .. " vein! Mining completely...")
                    
                    -- Dig the ore block
                    turtle.digDown()
                    status.autoReport()
                    
                    -- Move INTO the ore's position
                    if movement.down() then
                        local blocksMinedBefore = 0
                        for _ in pairs(minedBlocks) do
                            blocksMinedBefore = blocksMinedBefore + 1
                        end
                        
                        -- Mine the vein from inside
                        mineVeinRecursive(oreName, 0)
                        
                        local blocksMinedAfter = 0
                        for _ in pairs(minedBlocks) do
                            blocksMinedAfter = blocksMinedAfter + 1
                        end
                        
                        local totalMined = blocksMinedAfter - blocksMinedBefore
                        print("Vein complete: mined " .. totalMined .. " ore blocks")
                        status.reportEvent("Vein complete", totalMined .. " blocks mined")
                        
                        -- Return to original position
                        navigateToPosition(veinStartPos.x, veinStartPos.y, veinStartPos.z, veinStartFacing)
                    end
                    
                    veinMiningActive = false
                    clearMinedTracking()
                else
                    -- Just dig normally
                    turtle.digDown()
                    status.autoReport()
                end
                
                return true
            end
        end

        turtle.digDown()
        status.autoReport()
        return true
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

        -- Save the X/Z column we should descend through (may differ from homePos if
        -- moveToNewCorridor has shifted the turtle's horizontal position)
        local descentX = ctx.position.x
        local descentZ = ctx.position.z

        while ctx.position.y > targetY do
            if not movement.safeDown(digDown) then
                status.reportError("Cannot descend further")
                return false
            end

            -- Check for ores while descending
            checkSurroundings()

            -- Check fuel (burns carried fuel first) - stop if still too low
            if not inventory.checkFuel() then
                status.reportWarning("Low fuel during descent, returning home")
                return false
            end

            -- Check inventory
            local emptySlots = inventory.checkInventory()
            if emptySlots < 2 then
                status.reportEvent("Full inventory during descent", "pausing to dump")
                -- Save current position before going home
                local resumeY = ctx.position.y
                local savedFacing = ctx.facing
                
                movement.returnHome()
                inventory.emptyInventory()
                
                -- Navigate back to the descent column (X/Z) before continuing down.
                -- This is necessary because homePos X/Z may differ from the descent
                -- column after moveToNewCorridor has repositioned the turtle.
                status.reportEvent("Resuming descent", "returning to descent column")
                if not navigateToXZ(descentX, descentZ) then
                    status.reportError("Cannot return to descent column")
                    return false
                end
                while ctx.facing ~= savedFacing do movement.turnRight() end
                
                -- Return to the Y level we were at before going home
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
                -- Check for interrupt before each iteration
                if ctx.commandInterrupt then
                    print("Command interrupt detected during branch mining")
                    status.reportEvent("Interrupted", "stopping branch")
                    result = "COMMAND_STOP"
                    return
                end

                -- Dig forward and move
                if not movement.safeForward(digForward) then
                    -- Check if it was an interrupt or actual stuck
                    if ctx.commandInterrupt then
                        result = "COMMAND_STOP"
                    else
                        status.reportError("Stuck while mining branch")
                        result = "STUCK"
                    end
                    return
                end

                -- Check surroundings for ores
                checkSurroundings()

                -- Status update every 5 blocks
                if i % 5 == 0 then
                    status.reportEvent("Mining", string.format("Block %d/%d", i, length))
                end

                -- ===== FUEL CHECK =====
                if not inventory.checkFuel() then
                    status.reportWarning("CRITICAL: Low fuel during branch")
                    print("CRITICAL LOW FUEL - must return home NOW")
                    result = "CRITICAL_FUEL"
                    return
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
                    error("REMOTE_INTERRUPT", 0)  -- level 0 = no position annotation
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
        
        -- Return to surface to empty inventory
        movement.returnHome()
        inventory.emptyInventory()

        -- Descend to mining depth BEFORE shifting horizontally.
        -- Moving at surface level would grief above-ground structures.
        status.reportEvent("Repositioning", "descending before horizontal shift")
        if not descendToTarget() then
            status.reportError("Cannot descend for new corridor")
            return false
        end

        -- Now shift perpendicular underground to the new corridor position
        status.reportEvent("Repositioning", "finding new corridor")
        print("Shifting to new corridor position (underground)...")
        
        movement.turnRight()
        for i = 1, CONFIG.BRANCH_SPACING * 2 do
            if not movement.safeForward(digForward) then
                status.reportWarning("Cannot shift to new corridor position")
                movement.turnLeft()
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

                    -- Record exactly where this branch starts so we can return here
                    -- if we have to leave mid-branch for an inventory dump.
                    local branchStartX       = ctx.position.x
                    local branchStartY       = ctx.position.y
                    local branchStartZ       = ctx.position.z
                    local branchStartFacing  = ctx.facing

                    -- Mine a branch
                    local result = runMineBranch(CONFIG.BRANCH_LENGTH)
                    
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
                        -- Inventory full - return home, dump, navigate back, and CONTINUE mining
                        print("Inventory full - dumping and resuming")
                        status.reportEvent("Inventory full", "returning to dump")
                        
                        movement.returnHome()
                        inventory.emptyInventory()
                        
                        -- Check fuel after returning
                        if not inventory.checkFuel(CONFIG.FUEL_RESERVE_MULTIPLIER * 2) then
                            print("Not enough fuel to continue mining")
                            status.reportWarning("Insufficient fuel to resume")
                            corridorActive = false
                            break
                        end
                        
                        -- Descend back to mining level (straight down from home)
                        status.reportEvent("Resuming", "returning to mining depth")
                        if not descendToTarget() then
                            corridorActive = false
                            break
                        end
                        
                        -- Navigate back to the branch-start position in X/Z so the
                        -- next runMineBranch call starts from the right place.
                        -- (descendToTarget only restores Y; it leaves us at home X/Z.)
                        status.reportEvent("Resuming", "navigating back to branch position")
                        if not navigateToXZ(branchStartX, branchStartZ) then
                            status.reportWarning("Cannot return to branch position - ending corridor")
                            corridorActive = false
                            break
                        end
                        -- Also restore the correct facing for this branch direction
                        while ctx.facing ~= branchStartFacing do movement.turnRight() end
                        -- loop continues: runMineBranch will re-walk the already-mined
                        -- tunnel quickly and continue from where it left off
                        
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
                    if not inventory.checkFuel() then
                        print("Low fuel detected - ending this corridor")
                        status.reportWarning("Low fuel - moving to new corridor")
                        corridorActive = false
                        break
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