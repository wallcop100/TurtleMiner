-- Version: 1.1.1
-- Ore detection and mining logic for TurtleMiner

local function createMiningModule(ctx, status, movement, inventory)
    local CONFIG = ctx.CONFIG
    local MINED_PROTOCOL = "TURTLE_MINED_DB"

    -- Query central database to see if a block has already been mined
    local function isBlockMined(x, y, z)
        local mined = false
        local ok = pcall(function()
            rednet.broadcast({
                type = "CHECK_BLOCK",
                x = x,
                y = y,
                z = z,
            }, MINED_PROTOCOL)

            local timeout = 0.3
            local senderId, message, protocol = rednet.receive(MINED_PROTOCOL, timeout)
            if senderId and protocol == MINED_PROTOCOL and type(message) == "table" and
               message.type == "BLOCK_STATUS" and
               message.x == x and message.y == y and message.z == z then
                mined = message.mined and true or false
            end
        end)

        if not ok then
            return false
        end

        return mined
    end

    local function sampleBranchPositions()
        -- Sample the first, middle, and last block of the branch
        local function offsetPos(steps)
            local x, y, z = ctx.position.x, ctx.position.y, ctx.position.z
            if ctx.facing == 0 then
                z = z - steps
            elseif ctx.facing == 1 then
                x = x + steps
            elseif ctx.facing == 2 then
                z = z + steps
            elseif ctx.facing == 3 then
                x = x - steps
            end
            return x, y, z
        end

        local samples = {}
        local mid = math.floor(CONFIG.BRANCH_LENGTH / 2)
        table.insert(samples, { offsetPos(1) })
        table.insert(samples, { offsetPos(mid) })
        table.insert(samples, { offsetPos(CONFIG.BRANCH_LENGTH) })
        return samples
    end

    -- Check if block is valuable ore
    local function isValuableOre(blockData)
        if not blockData or not blockData.name then
            return false
        end

        for _, ore in ipairs(CONFIG.VALUABLE_ORES) do
            if blockData.name == ore then
                return true
            end
        end
        return false
    end

    -- Smart dig with ore detection
    local function digForward()
        local hasBlock, blockData = turtle.inspect()

        if hasBlock then
            if isValuableOre(blockData) then
                ctx.totalOresMined = ctx.totalOresMined + 1
                status.report("Found " .. blockData.name .. "! Total: " .. ctx.totalOresMined)
                print("ORE FOUND: " .. blockData.name)
            end

            turtle.dig()
            return true
        end
        return false
    end

    local function digUp()
        local hasBlock, blockData = turtle.inspectUp()

        if hasBlock then
            if isValuableOre(blockData) then
                ctx.totalOresMined = ctx.totalOresMined + 1
                status.report("Found " .. blockData.name .. "! Total: " .. ctx.totalOresMined)
                print("ORE FOUND: " .. blockData.name)
            end

            turtle.digUp()
            return true
        end
        return false
    end

    local function digDown()
        local hasBlock, blockData = turtle.inspectDown()

        if hasBlock then
            if isValuableOre(blockData) then
                ctx.totalOresMined = ctx.totalOresMined + 1
                status.report("Found " .. blockData.name .. "! Total: " .. ctx.totalOresMined)
                print("ORE FOUND: " .. blockData.name)
            end

            turtle.digDown()
            return true
        end
        return false
    end

    -- Check surrounding blocks for ores (including recursive exploration)
    local function checkSurroundings()
        if not CONFIG.CHECK_SURROUNDING then
            return
        end

        -- Check all 4 horizontal directions
        for _ = 1, 4 do
            local hasBlock, blockData = turtle.inspect()
            if hasBlock and isValuableOre(blockData) then
                digForward()
                local ok = movement.forward()
                if ok then
                    checkSurroundings()
                    movement.back()
                end
            end
            movement.turnRight()
        end

        -- Check up
        local hasBlockUp, blockDataUp = turtle.inspectUp()
        if hasBlockUp and isValuableOre(blockDataUp) then
            digUp()
            if movement.up() then
                checkSurroundings()
                movement.down()
            end
        end

        -- Check down
        local hasBlockDown, blockDataDown = turtle.inspectDown()
        if hasBlockDown and isValuableOre(blockDataDown) then
            digDown()
            if movement.down() then
                checkSurroundings()
                movement.up()
            end
        end
    end

    -- Descend to mining level (tunnel-aware)
    local function descendToMiningLevel()
        if ctx.position.y == ctx.miningY then
            status.report("At mining level Y=" .. ctx.miningY)
            return true
        end

        status.report("Descending to mining level Y=" .. ctx.miningY)
        print("Descending to mining level (Y=" .. ctx.miningY .. ")...")

        while ctx.position.y > ctx.miningY do
            -- Check if there's already a tunnel below (air block)
            local hasBlock = turtle.inspectDown()

            if not hasBlock then
                -- Air below - existing tunnel, just move down
                if not movement.down() then
                    digDown()
                    if not movement.safeDown(digDown) then
                        status.report("ERROR: Failed to descend")
                        return false
                    end
                end
            else
                -- Block below - need to dig
                digDown()
                if not movement.safeDown(digDown) then
                    status.report("ERROR: Failed to descend")
                    return false
                end
            end
        end

        while ctx.position.y < ctx.miningY do
            digUp()
            if not movement.safeUp(digUp) then
                status.report("ERROR: Failed to ascend")
                return false
            end
        end

        print("Reached mining level Y=" .. ctx.miningY)
        status.report("At mining level Y=" .. ctx.miningY)
        return true
    end

    -- Mine a single branch
    local function mineBranch()
        local branchNum = ctx.currentBranch + 1
        status.report("Mining branch #" .. branchNum .. " at Y=" .. ctx.position.y)

        -- Quick check with the central DB: if all sampled positions along this branch
        -- are already marked as mined, skip this branch entirely.
        local allSampledMined = true
        for _, sample in ipairs(sampleBranchPositions()) do
            local sx, sy, sz = sample[1], sample[2], sample[3]
            if not isBlockMined(sx, sy, sz) then
                allSampledMined = false
                break
            end
        end

        if allSampledMined then
            print("Branch #" .. branchNum .. " appears already mined; skipping.")
            status.report("Skipping branch #" .. branchNum .. " (already mined)")
            return true
        end

        for i = 1, CONFIG.BRANCH_LENGTH do
            -- Dig forward, up, and down (creates 1x2 tunnel)
            digForward()
            digUp()
            digDown()

            if not movement.safeForward(digForward) then
                status.report("ERROR: Stuck in branch at block " .. i)
                return false
            end

            -- Check surroundings for ores
            checkSurroundings()

            -- Report progress every 5 blocks
            if i % 5 == 0 then
                status.report("Branch #" .. branchNum .. ": " .. i .. "/" .. CONFIG.BRANCH_LENGTH .. " blocks")
            end

            -- Check fuel and inventory
            if not inventory.checkFuel() then
                status.report("Low fuel during branch mining")
                return false
            end

            local emptySlots = inventory.checkInventory()
            if emptySlots < 2 then
                status.report("Inventory full mid-branch")
                return false
            end
        end

        -- Return to main tunnel
        status.report("Branch #" .. branchNum .. " complete - returning")
        movement.turnAround()
        for _ = 1, CONFIG.BRANCH_LENGTH do
            movement.safeForward(digForward)
        end
        movement.turnAround()

        return true
    end

    -- Move to next branch position
    local function moveToNextBranch()
        for _ = 1, CONFIG.BRANCH_SPACING do
            digForward()
            digUp()  -- Also dig up to maintain 1x2 tunnel
            if not movement.safeForward(digForward) then
                return false
            end
        end
        return true
    end

    -- Check for and install software updates (non-blocking)
    local function checkForUpdates()
        if not fs.exists("turtle_updater.lua") then
            print("Update system not available")
            return false
        end

        status.report("Checking for updates...")
        print("Checking for software updates...")

        -- Run updater with timeout protection
        local ok = pcall(function()
            os.queueEvent("update_timeout")
            local timer = os.startTimer(15)  -- 15 second timeout

            parallel.waitForAny(
                function()
                    -- Let updater decide which files to update
                    shell.run("turtle_updater")
                end,
                function()
                    while true do
                        local event = { os.pullEvent() }
                        if event[1] == "timer" or event[1] == "update_timeout" then
                            break
                        end
                    end
                end
            )

            os.cancelTimer(timer)
        end)

        -- Clear the update status message
        if ok then
            print("Update check complete")
            status.report("Ready to resume mining")
        else
            print("Update check skipped")
            status.report("Resuming mining")
        end

        sleep(1)  -- Brief pause to ensure status clears
        return true
    end

    -- Main mining loop
    local function mine()
        status.report("Starting mining operations")
        print("=== Starting Mining ===")

        -- Auto-descend to target level if configured
        if CONFIG.AUTO_DESCEND and ctx.position.y > CONFIG.TARGET_Y_LEVEL then
            status.report("Descending to Y=" .. CONFIG.TARGET_Y_LEVEL)
            print("Auto-descending to Y=" .. CONFIG.TARGET_Y_LEVEL)

            while ctx.position.y > CONFIG.TARGET_Y_LEVEL do
                digDown()
                if not movement.safeDown(digDown) then
                    status.report("ERROR: Failed to descend")
                    return
                end
            end

            ctx.miningY = ctx.position.y
            print("Reached target Y-level: " .. ctx.miningY)
            status.report("At mining level Y=" .. ctx.miningY)
        else
            ctx.miningY = ctx.position.y
            print("Mining at current level: " .. ctx.miningY)
            status.report("Starting at Y=" .. ctx.miningY)
        end

        local cycleCount = 0

        while true do
            status.report("Branch " .. ctx.currentBranch ..
                          " | Ores: " .. ctx.totalOresMined ..
                          " | Fuel: " .. turtle.getFuelLevel())

            -- Fuel check
            if not inventory.checkFuel() then
                status.report("Low fuel - returning home")
                print("Low fuel! Returning home...")
                if not movement.returnHome() then
                    break
                end

                status.report("Attempting auto-refuel...")
                if inventory.autoRefuel() then
                    print("Auto-refuel successful!")
                    status.report("Refueled successfully")
                    if not descendToMiningLevel() then
                        break
                    end
                else
                    print("Add fuel and press Enter, or Ctrl+T to quit")
                    status.report("Waiting for manual refuel...")
                    read()

                    if not inventory.autoRefuel() then
                        if turtle.getFuelLevel() < CONFIG.MIN_FUEL_TO_START then
                            status.report("Insufficient fuel - stopping")
                            break
                        end
                    end

                    if not descendToMiningLevel() then
                        break
                    end
                end
            end

            -- Inventory check
            local emptySlots = inventory.checkInventory()
            if emptySlots < 3 then
                status.report("Inventory full (" .. (16 - emptySlots) .. "/16) - returning")
                print("Inventory nearly full! Returning...")
                if not movement.returnHome() then
                    break
                end

                if not inventory.emptyInventory() then
                    print("WARNING: Failed to empty inventory")
                    status.report("WARNING: Container may be full")
                end

                if not descendToMiningLevel() then
                    break
                end
            end

            -- Execute mining pattern
            if CONFIG.MINING_PATTERN == "branch" then
                print("Mining branch #" .. (ctx.currentBranch + 1))

                -- Mine right branch
                movement.turnRight()
                local okRight = mineBranch()
                movement.turnLeft()

                if okRight then
                    ctx.currentBranch = ctx.currentBranch + 1
                    status.report("Completed branch #" .. ctx.currentBranch .. " (right)")

                    -- Move forward in main tunnel
                    if not moveToNextBranch() then
                        print("Failed to move to next position")
                        status.report("ERROR: Stuck at branch position")
                        break
                    end

                    -- Mine left branch
                    movement.turnLeft()
                    local okLeft = mineBranch()
                    movement.turnRight()

                    if okLeft then
                        ctx.currentBranch = ctx.currentBranch + 1
                        status.report("Completed branch #" .. ctx.currentBranch .. " (left)")
                    end
                else
                    -- Branch failed - might need to return home
                    if not movement.returnHome() then
                        break
                    end
                    if not inventory.emptyInventory() then
                        break
                    end
                    if not descendToMiningLevel() then
                        break
                    end
                end

                -- Return home every 5 branches
                if ctx.currentBranch >= 5 and ctx.currentBranch % 5 == 0 then
                    cycleCount = cycleCount + 1
                    status.report("Completed 5 branches (cycle #" .. cycleCount .. ") - returning")
                    print("Completed 5 branches, returning home")

                    if not movement.returnHome() then
                        break
                    end

                    if not inventory.emptyInventory() then
                        print("WARNING: Failed to empty inventory")
                    end

                    -- Check for software updates after every cycle
                    print("")
                    print("=== Checking for updates ===")
                    checkForUpdates()
                    print("")

                    -- Descend back to mining level
                    if not descendToMiningLevel() then
                        break
                    end
                end
            else
                print("ERROR: Only 'branch' pattern supported")
                status.report("ERROR: Unsupported mining pattern")
                break
            end

            sleep(0.5)
        end

        -- Final return
        status.report("Mining complete - returning home")
        print("Mining operations ending...")
        movement.returnHome()
        inventory.emptyInventory()

        status.report("Mining finished. Ores: " .. ctx.totalOresMined .. ", Branches: " .. ctx.currentBranch)
    end

    return {
        mine = mine,
        descendToMiningLevel = descendToMiningLevel,
    }
end

return createMiningModule

