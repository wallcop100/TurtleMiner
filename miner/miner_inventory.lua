-- Version: 2.0.0
-- Enhanced Inventory Management with Detailed Status Reporting

local function createInventoryModule(ctx, status, movement)
    local CONFIG = ctx.CONFIG

    -- Burn fuel items from inventory one at a time until fuel >= target.
    -- target defaults to the turtle's fuel limit (burn everything).
    -- Returns true if fuel is at/above target afterwards.
    local function refuelTo(target)
        local fuel = turtle.getFuelLevel()
        if fuel == "unlimited" then return true end

        local limit = turtle.getFuelLimit()
        if not target or target > limit then target = limit end
        if fuel >= target then return true end

        local originalSlot = turtle.getSelectedSlot()
        for slot = 1, 16 do
            if turtle.getFuelLevel() >= target then break end
            if turtle.getItemCount(slot) > 0 then
                turtle.select(slot)
                -- refuel(1) returns false for non-fuel items (and empty buckets)
                while turtle.getFuelLevel() < target
                      and turtle.getItemCount(slot) > 0
                      and turtle.refuel(1) do
                end
            end
        end
        turtle.select(originalSlot)

        local gained = turtle.getFuelLevel() - fuel
        if gained > 0 then
            print("Refueled +" .. gained .. " (now " .. turtle.getFuelLevel() .. ")")
            status.reportEvent("Refueled", "+" .. gained .. " fuel")
        end
        return turtle.getFuelLevel() >= target
    end

    -- Auto-refuel from inventory (used at startup). Returns true if any fuel
    -- was added or the tank is already full.
    local function autoRefuel(target)
        local fuel = turtle.getFuelLevel()
        if fuel == "unlimited" then return true end

        print("Searching for fuel in inventory...")
        refuelTo(target)

        local newFuel = turtle.getFuelLevel()
        if newFuel > fuel or newFuel >= turtle.getFuelLimit() then
            return true
        end
        status.reportWarning("No fuel items found")
        print("No fuel items found in inventory")
        return false
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

        -- Top up from carried fuel before dumping, then keep one fuel
        -- stack (coal preferred) so the turtle can refuel later underground
        refuelTo(CONFIG.FUEL_THRESHOLD)
        local keepSlot, keepScore = nil, -1
        for i = 1, 16 do
            local detail = turtle.getItemDetail(i)
            if detail then
                turtle.select(i)
                if turtle.refuel(0) then
                    local score = detail.count
                    if detail.name:find("coal") then score = score + 1000 end
                    if score > keepScore then keepSlot, keepScore = i, score end
                end
            end
        end
        if keepSlot then
            print("Keeping fuel in slot " .. keepSlot)
        end

        -- Drop all items
        local itemsDropped = 0
        local failedSlots = {}

        for i = 1, 16 do
            turtle.select(i)
            if i ~= keepSlot and turtle.getItemCount(i) > 0 then
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

    -- Fuel safety check. Burns carried fuel first if running low, and only
    -- returns false if there still isn't enough to get home.
    -- multiplier defaults to CONFIG.FUEL_RESERVE_MULTIPLIER.
    local function checkFuel(multiplier)
        local fuel = turtle.getFuelLevel()
        if fuel == "unlimited" then return true end

        local distanceHome = math.abs(ctx.position.x - ctx.homePos.x) +
                             math.abs(ctx.position.y - ctx.homePos.y) +
                             math.abs(ctx.position.z - ctx.homePos.z)
        local fuelNeeded = distanceHome * (multiplier or CONFIG.FUEL_RESERVE_MULTIPLIER)

        -- Top up from inventory before it becomes a problem
        local topUp = math.max(CONFIG.FUEL_THRESHOLD, fuelNeeded * 2)
        if fuel < topUp then
            refuelTo(topUp)
            fuel = turtle.getFuelLevel()
        end

        if fuel < fuelNeeded then
            status.reportWarning("Low fuel: " .. fuel .. " < " .. fuelNeeded .. " needed")
            print("Low fuel! Current: " .. fuel .. ", needed: " .. fuelNeeded ..
                  " (distance home " .. distanceHome .. ")")
            return false
        end
        return true
    end

    return {
        autoRefuel = autoRefuel,
        refuelTo = refuelTo,
        checkInventory = checkInventory,
        findStorage = findStorage,
        emptyInventory = emptyInventory,
        checkFuel = checkFuel,
    }
end

return createInventoryModule