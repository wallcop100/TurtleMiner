-- Version: 2.0.0
-- Enhanced Inventory Management with Detailed Status Reporting

local function createInventoryModule(ctx, status, movement)
    local CONFIG = ctx.CONFIG

    -- Auto-refuel from inventory with detailed reporting
    local function autoRefuel()
        local currentFuel = turtle.getFuelLevel()

        if currentFuel == "unlimited" then
            return true
        end

        status.reportEvent("Refueling", "searching for fuel")
        print("Searching for fuel in inventory...")

        local refueled = false
        local originalSlot = turtle.getSelectedSlot()
        local totalFuelAdded = 0

        -- Try to refuel from each slot
        for slot = 1, 16 do
            if turtle.getItemCount(slot) > 0 then
                turtle.select(slot)
                local itemsBefore = turtle.getItemCount(slot)

                -- Check if this item is fuel
                if turtle.refuel(0) then
                    local fuelBefore = turtle.getFuelLevel()
                    turtle.refuel(64)
                    local fuelAfter = turtle.getFuelLevel()

                    if fuelAfter > fuelBefore then
                        local itemsAfter = turtle.getItemCount(slot)
                        local consumed = itemsBefore - itemsAfter
                        local fuelGained = fuelAfter - fuelBefore
                        
                        print("Refueled with " .. consumed .. " items from slot " .. slot)
                        print("Fuel gained: " .. fuelGained)
                        
                        totalFuelAdded = totalFuelAdded + fuelGained
                        refueled = true
                    end
                end
            end
        end

        turtle.select(originalSlot)

        if refueled then
            status.reportEvent("Refueled", "+" .. totalFuelAdded .. " fuel")
            print("Total fuel added: " .. totalFuelAdded)
            print("New fuel level: " .. turtle.getFuelLevel())
        else
            status.reportWarning("No fuel items found")
            print("No fuel items found in inventory")
        end

        return refueled
    end

    -- Check inventory usage with detailed reporting
    local function checkInventory()
        local emptySlots = 0
        local totalItems = 0
        local slotDetails = {}

        for i = 1, 16 do
            local count = turtle.getItemCount(i)
            if count == 0 then
                emptySlots = emptySlots + 1
            else
                totalItems = totalItems + count
                local detail = turtle.getItemDetail(i)
                if detail then
                    table.insert(slotDetails, {
                        slot = i,
                        name = detail.name,
                        count = count
                    })
                end
            end
        end

        local usedSlots = 16 - emptySlots
        
        -- Report inventory status
        if emptySlots <= 2 then
            status.reportWarning("Inventory nearly full: " .. usedSlots .. "/16 slots")
        elseif emptySlots <= 5 then
            status.reportEvent("Inventory", usedSlots .. "/16 slots used")
        end

        return emptySlots, totalItems
    end

    -- Locate nearby storage with enhanced detection
    local function findStorage()
        status.reportEvent("Storage scan", "checking adjacent blocks")
        
        -- Check down first (most common)
        local hasBlock, blockData = turtle.inspectDown()
        if hasBlock and blockData and blockData.name then
            if blockData.name:find("chest") or
               blockData.name:find("barrel") or
               blockData.name:find("shulker") then
                print("Found storage down: " .. blockData.name)
                return "down", blockData.name
            end
        end

        -- Check forward
        hasBlock, blockData = turtle.inspect()
        if hasBlock and blockData and blockData.name then
            if blockData.name:find("chest") or
               blockData.name:find("barrel") or
               blockData.name:find("shulker") then
                print("Found storage forward: " .. blockData.name)
                return "forward", blockData.name
            end
        end

        -- Check right
        movement.turnRight()
        hasBlock, blockData = turtle.inspect()
        movement.turnLeft()
        if hasBlock and blockData and blockData.name then
            if blockData.name:find("chest") or
               blockData.name:find("barrel") or
               blockData.name:find("shulker") then
                print("Found storage right: " .. blockData.name)
                return "right", blockData.name
            end
        end

        -- Check back
        movement.turnAround()
        hasBlock, blockData = turtle.inspect()
        movement.turnAround()
        if hasBlock and blockData and blockData.name then
            if blockData.name:find("chest") or
               blockData.name:find("barrel") or
               blockData.name:find("shulker") then
                print("Found storage back: " .. blockData.name)
                return "back", blockData.name
            end
        end

        -- Check left
        movement.turnLeft()
        hasBlock, blockData = turtle.inspect()
        movement.turnRight()
        if hasBlock and blockData and blockData.name then
            if blockData.name:find("chest") or
               blockData.name:find("barrel") or
               blockData.name:find("shulker") then
                print("Found storage left: " .. blockData.name)
                return "left", blockData.name
            end
        end

        status.reportWarning("No storage container found")
        return nil, nil
    end

    -- Empty inventory into storage with detailed progress
    local function emptyInventory()
        status.reportEvent("Inventory dump", "starting")
        print("Emptying inventory...")

        -- Count items before dumping
        local emptySlots, totalItems = checkInventory()
        local itemsToDump = 16 - emptySlots
        
        print("Items to dump: " .. itemsToDump .. " slots")

        -- Use cached storage if available, otherwise find it
        local storageDir = ctx.storageDirection
        local storageName_local = ctx.storageName

        if not storageDir then
            status.reportEvent("Storage", "locating container")
            storageDir, storageName_local = findStorage()
            -- Cache for next time
            ctx.storageDirection = storageDir
            ctx.storageName = storageName_local
        end

        if not storageDir then
            print("")
            print("========================================")
            print("ERROR: NO STORAGE CONTAINER FOUND!")
            print("========================================")
            print("Checked: down, forward, back, left, right")
            print("")
            print("Items will be DROPPED ON THE GROUND if you continue!")
            print("")
            print("Press Enter to drop items or Ctrl+T to abort...")
            read()

            status.reportWarning("No storage - dropping items")
            storageDir = "down"
            storageName_local = "ground"
        else
            print("Using storage: " .. storageName_local .. " (" .. storageDir .. ")")
            status.reportEvent("Dumping to", storageName_local)
        end

        -- Turn to face storage ONCE
        local originalFacing = ctx.facing
        if storageDir == "right" then
            movement.turnRight()
        elseif storageDir == "back" then
            movement.turnAround()
        elseif storageDir == "left" then
            movement.turnLeft()
        end

        -- Drop all items
        local itemsDropped = 0
        local failedSlots = {}

        for i = 1, 16 do
            turtle.select(i)
            if turtle.getItemCount(i) > 0 then
                local ok = false

                if storageDir == "down" then
                    ok = turtle.dropDown()
                else
                    ok = turtle.drop()
                end

                if ok then
                    itemsDropped = itemsDropped + 1
                    
                    -- Report progress every 4 slots
                    if itemsDropped % 4 == 0 then
                        status.reportEvent("Dumping", itemsDropped .. "/" .. itemsToDump .. " slots")
                    end
                else
                    table.insert(failedSlots, i)
                end
            end
        end

        -- Turn back to original direction
        while ctx.facing ~= originalFacing do
            movement.turnRight()
        end

        turtle.select(1)

        if #failedSlots > 0 then
            print("WARNING: Could not drop " .. #failedSlots .. " slot(s)")
            print("Container may be FULL!")
            status.reportWarning("Storage full! " .. #failedSlots .. " slots remain")

            print("")
            print("Failed slots: " .. table.concat(failedSlots, ", "))
            print("Press Enter to continue or Ctrl+T to abort...")
            read()
            return false
        else
            print("Successfully emptied " .. itemsDropped .. " slots")
            status.reportEvent("Inventory cleared", itemsDropped .. " slots dumped")
            return true
        end
    end

    -- Fuel safety check with detailed warnings
    local function checkFuel()
        local fuel = turtle.getFuelLevel()

        if fuel == "unlimited" then
            return true
        end

        local distanceHome = math.abs(ctx.position.x - ctx.homePos.x) +
                             math.abs(ctx.position.y - ctx.homePos.y) +
                             math.abs(ctx.position.z - ctx.homePos.z)

        local fuelNeeded = distanceHome * CONFIG.FUEL_RESERVE_MULTIPLIER

        if fuel < fuelNeeded then
            status.reportWarning("Low fuel: " .. fuel .. " < " .. fuelNeeded .. " needed")
            print("Low fuel warning!")
            print("Current: " .. fuel)
            print("Distance home: " .. distanceHome)
            print("Fuel needed: " .. fuelNeeded)
            return false
        end

        -- Early warning at 2x threshold
        if fuel < fuelNeeded * 2 then
            status.reportEvent("Fuel status", "getting low (" .. fuel .. ")")
        end

        return true
    end

    return {
        autoRefuel = autoRefuel,
        checkInventory = checkInventory,
        findStorage = findStorage,
        emptyInventory = emptyInventory,
        checkFuel = checkFuel,
    }
end

return createInventoryModule