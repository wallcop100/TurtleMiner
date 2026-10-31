-- Version: 1.0.0
-- Scenario 28 (review #10, #11), driving mine/inv directly in a hand-dug grid
-- (home (0,0,0) facing north, TARGET_Y -6, BRANCH_LENGTH 4, SPACING 3, W = 11).
-- The turtle sits at the far end of corridor 1's left branch (f=4, r=7).
--   #11 fuelNeeded uses the real tunnel route home (25 blocks: 4 back to the main, 3 to the
--       spine, 11 along it, 1 to the shaft, 6 up), not Manhattan (17); plus the vein
--       backtrack depth while vein mining; Manhattan + margin when mine isn't initialised.
--   #10 mine.retreat and the vein backtrack never dig a protected block (chest) in their
--       way: they stop with "stuck" and say why; the chest stays.
local START = { x = 7, y = -6, z = -4 }
local MARGIN = 20

local function grid(w)
    local function open(x1, y1, z1, x2, y2, z2)
        for x = math.min(x1, x2), math.max(x1, x2) do
            for y = math.min(y1, y2), math.max(y1, y2) do
                for z = math.min(z1, z2), math.max(z1, z2) do w:set(x, y, z, "air") end
            end
        end
    end
    open(0, -6, 0, 0, -1, 0)      -- shaft
    open(0, -6, -1, 11, -6, -1)   -- spine (f = 1)
    open(11, -6, -1, 11, -6, -8)  -- corridor 1 main (r = 11)
    open(7, -6, -4, 10, -6, -4)   -- corridor 1, branch 0, left side
end

local function setup(H, opts)
    opts = opts or {}
    return H.mineDriver({ pos = START, facing = 3, fuel = 1000, noMineInit = opts.noMineInit,
        job = { corridor = 1, branch = 0, side = "L", step = 4 },
        settings = { FUEL_MARGIN = MARGIN, VEIN_MAX = 16 }, world = function(w)
            grid(w)
            if opts.world then opts.world(w) end
        end })
end

return {
    title = "real route home for fuel; retreat/backtrack never dig protected blocks",
    needs = { "config", "state", "nav", "inv", "mine" },
    run = function(sim, H)
        -- #11 without mine.init: Manhattan + margin
        local ctx = setup(H, { noMineInit = true })
        local r = ctx.run("return inv.fuelNeeded(st)")
        H.check(r.ret[1] == 17 + MARGIN, "fallback fuelNeeded should be Manhattan 17 + %d, got %s", MARGIN, tostring(r.ret[1]))

        -- #11 route length + #10 retreat blocked by a chest on the main
        sim.reset()
        ctx = setup(H, { world = function(w) w:chest(11, -6, -2, { { name = "minecraft:diamond", count = 3 } }) end })
        r = ctx.run([[
            local route, need = mine.routeHomeLength(), inv.fuelNeeded(st)
            local ok, reason, detail = mine.retreat()
            return route, need, ok, reason, detail, st.pos.x, st.pos.y, st.pos.z
        ]])
        local route, need, ok, reason, detail = r.ret[1], r.ret[2], r.ret[3], r.ret[4], r.ret[5]
        H.check(route == 25, "routeHomeLength should be 25, got %s", tostring(route))
        H.check(need == 25 + MARGIN, "fuelNeeded should be route 25 + %d, got %s", MARGIN, tostring(need))
        H.check(ok == false and reason == "stuck" and tostring(detail):find("protected", 1, true),
            "retreat into a chest should fail stuck/protected, got %s %s %s", tostring(ok), tostring(reason), tostring(detail))
        H.check(ctx.w:get(11, -6, -2) == "minecraft:chest", "the chest was dug: now %s", tostring(ctx.w:get(11, -6, -2)))
        H.check(ctx.w:chestCount(11, -6, -2, "minecraft:diamond") == 3, "chest contents changed")
        H.check(H.samePos(ctx.t.pos, { x = 11, y = -6, z = -3 }), "turtle should wait next to the chest, at %s", H.fmtPos(ctx.t.pos))
        H.check(r.ret[6] == 11 and r.ret[8] == -3, "believed position wrong: %s,%s,%s", tostring(r.ret[6]), tostring(r.ret[7]), tostring(r.ret[8]))

        -- #11 vein depth: 3-block iron vein off the branch end wall
        local vein = { { 7, -6, -5 }, { 7, -6, -6 }, { 7, -7, -6 } }
        local function ores(w) for _, v in ipairs(vein) do w:set(v[1], v[2], v[3], "minecraft:iron_ore") end end
        sim.reset()
        ctx = setup(H, { world = ores })
        r = ctx.run([[
            local n, sig, why = mine.vein("iron")
            local deep
            for _, e in ipairs(ctlLog) do
                if e.pos.x == 7 and e.pos.y == -7 and e.pos.z == -6 then deep = e.need end
            end
            return n, sig, deep, mine.routeHomeLength(), st.pos.x, st.pos.z
        ]])
        H.check(r.ret[1] == 3 and r.ret[2] == nil, "vein should mine 3 blocks cleanly, got %s %s", tostring(r.ret[1]), tostring(r.ret[2]))
        H.check(r.ret[3] == 25 + 3 + MARGIN, "fuelNeeded 3 deep in the vein should be 25 + 3 + %d, got %s", MARGIN, tostring(r.ret[3]))
        H.check(r.ret[4] == 25, "routeHomeLength after the vein should be 25 again, got %s", tostring(r.ret[4]))

        -- #10 vein backtrack: a chest appears in the vein path behind the turtle
        sim.reset()
        ctx = setup(H, { world = ores })
        local placed = false
        sim.addHook(ctx.t, function(e)
            if not placed and e.op == "down" and e.ok and H.samePos(ctx.t.pos, { x = 7, y = -7, z = -6 }) then
                placed = true
                ctx.w:chest(7, -6, -6, { { name = "minecraft:diamond", count = 1 } })
            end
        end)
        r = ctx.run([[
            local n, sig, why = mine.vein("iron")
            return n, sig, why
        ]])
        H.check(placed, "test setup: vein never reached its bottom block")
        H.check(r.ret[2] == "stuck" and tostring(r.ret[3]):find("protected", 1, true),
            "vein backtrack into a chest should be stuck/protected, got %s %s", tostring(r.ret[2]), tostring(r.ret[3]))
        H.check(ctx.w:get(7, -6, -6) == "minecraft:chest", "the chest in the vein path was dug")
        return "route 25 (Manhattan 17), vein +3; retreat and backtrack stop at chests: " .. tostring(r.ret[3])
    end,
}
