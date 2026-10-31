-- Version: 1.1.1
-- Inventory, fuel, and storage handling for TurtleMiner

local function createInventoryModule(ctx, status, movement)
    local CONFIG = ctx.CONFIG

    -- Auto-refuel from inventory
    local function autoRefuel()
        local currentFuel = turtle.getFuelLevel()

        if currentFuel == "unlimited" then
            return true
        end

        local refueled = false
        local originalSlot = turtle.getSelectedSlot()

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
                        print("Refueled with " .. consumed .. " items from slot " .. slot)
                        print("Fuel: " .. fuelBefore .. " -> " .. fuelAfter)
                        refueled = true
                    end
                end
            end
        end

        turtle.select(originalSlot)

        if refueled then
            status.report("Refueled to " .. turtle.getFuelLevel())
        end

        return refueled
    end

    -- Check inventory usage
    local function checkInventory()
        local emptySlots = 0
        local totalItems = 0

        for i = 1, 16 do
            if turtle.getItemCount(i) == 0 then
                emptySlots = emptySlots + 1
            else
                totalItems = totalItems + turtle.getItemCount(i)
            end
        end

        return emptySlots, totalItems
    end

    -- Locate nearby storage (chest/barrel/shulker)
    local function findStorage()
        -- Check down first (most common)
        local hasBlock, blockData = turtle.inspectDown()
        if hasBlock and blockData and blockData.name then
            if blockData.name:find("chest") or
               blockData.name:find("barrel") or
               blockData.name:find("shulker") then
                return "down", blockData.name
            end
        end

        -- Check forward
        hasBlock, blockData = turtle.inspect()
        if hasBlock and blockData and blockData.name then
            if blockData.name:find("chest") or
               blockData.name:find("barrel") or
               blockData.name:find("shulker") then
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
                return "left", blockData.name
            end
        end

        return nil, nil
    end

    -- Empty inventory into storage (or ground as fallback)
    local function emptyInventory()
        status.report("Emptying inventory...")
        print("Emptying inventory...")

        -- Use cached storage if available, otherwise find it
        local storageDir = ctx.storageDirection
        local storageName_local = ctx.storageName

        if not storageDir then
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

            status.report("WARNING: No chest - dropping items!")
            storageDir = "down"
            storageName_local = "ground"
        else
            print("Using storage: " .. storageName_local .. " (" .. storageDir .. ")")
            status.report("Dumping to " .. storageName_local)
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
        -- "forward" and "down" don't need turning

        -- Drop all items without additional turning
        local itemsDropped = 0
        local failedSlots = {}

        for i = 1, 16 do
            turtle.select(i)
            if turtle.getItemCount(i) > 0 then
                local ok = false

                if storageDir == "down" then
                    ok = turtle.dropDown()
                else
                    -- All horizontal directions now just use drop() since we're already facing it
                    ok = turtle.drop()
                end

                if ok then
                    itemsDropped = itemsDropped + 1
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
            status.report("Container full! " .. #failedSlots .. " slots remain")

            print("")
            print("Failed slots: " .. table.concat(failedSlots, ", "))
            print("Press Enter to continue or Ctrl+T to abort...")
            read()
            return false
        else
            print("Successfully emptied " .. itemsDropped .. " slots")
            status.report("Inventory emptied (" .. itemsDropped .. " slots)")
            return true
        end
    end

    -- Fuel safety check (used during mining)
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
            status.report("WARNING: Low fuel! Returning home")
            print("Low fuel warning! Current: " .. fuel .. ", Need: " .. fuelNeeded)
            return false
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

