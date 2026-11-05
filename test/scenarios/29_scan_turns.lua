-- Version: 1.0.0
-- Scenario 29 (review #1): a standard 2-corridor run makes few turns (turns are the
-- crash-ambiguous op), yet every block face the turtle opened up was looked at:
-- each solid neighbour of a dug cell was inspected (or dug itself).
-- Reference: 274 turns before the review-#1 change, 220 after.
return {
    title = "scan turn budget + no lost ore exposure",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 29, fuel = 5000 })
        local t = ctx.t
        local seen = {}
        local function k(x, y, z) return x .. "," .. y .. "," .. z end
        sim.addHook(t, function(e)
            if e.kind ~= "turtle" then return end
            local p = e.pos
            if e.op == "inspectUp" then seen[k(p.x, p.y + 1, p.z)] = true
            elseif e.op == "inspectDown" then seen[k(p.x, p.y - 1, p.z)] = true
            elseif e.op == "inspect" then
                local d = H.DIRS[e.facing]
                seen[k(p.x + d.x, p.y, p.z + d.z)] = true
            end
        end)
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 4 * 3600, "2 corridors then DONE at home")
        H.commonChecks(ctx)

        local dug = {}
        for _, d in ipairs(ctx.w.digLog) do
            if d.by == t.id and not d.rollback then dug[k(d.x, d.y, d.z)] = true end
        end
        local h = ctx.home
        local missed = {}
        local NB = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
        for key in pairs(dug) do
            local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            for _, n in ipairs(NB) do
                local nx, ny, nz = x + n[1], y + n[2], z + n[3]
                local nk = k(nx, ny, nz)
                local isHome = nx == h.x and ny == h.y and nz == h.z
                if not dug[nk] and not seen[nk] and not isHome and ny < h.y then
                    missed[#missed + 1] = nk
                end
            end
        end
        table.sort(missed)
        H.check(#missed == 0, "%d exposed faces never inspected, e.g. %s", #missed,
            table.concat(missed, " ", 1, math.min(8, #missed)))
        local turns = (t.opCounts.turnLeft or 0) + (t.opCounts.turnRight or 0)
        local moves = (t.opCounts.forward or 0) + (t.opCounts.back or 0) + (t.opCounts.up or 0) + (t.opCounts.down or 0)
        H.check(turns <= 235, "too many turns: %d (moves %d)", turns, moves)
        return string.format("turns %d, moves %d, inspects %d, dug %d", turns, moves,
            (t.opCounts.inspect or 0) + (t.opCounts.inspectUp or 0) + (t.opCounts.inspectDown or 0), #H.dugGrid(ctx))
    end,
}
