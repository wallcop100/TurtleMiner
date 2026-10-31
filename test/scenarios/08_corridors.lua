-- Version: 1.0.0
-- Scenario 8: corridor N+1 never overlaps corridor N. Every cell dug beyond the
-- spine lies inside exactly one corridor footprint |r - c*W| <= BRANCH_LENGTH, and
-- corridors are mined in order (the corridor index of digs never goes back).
return {
    title = "corridors never overlap",
    needs = { "config", "state", "nav", "inv", "mine", "net", "miner" },
    run = function(sim, H)
        local ctx = H.minerSetup({ id = 8, settings = { MAX_CORRIDORS = 3 } })
        local BL, BS = ctx.cfg.BRANCH_LENGTH, ctx.cfg.BRANCH_SPACING
        local W = 2 * BL + BS
        ctx.boot()
        H.runUntil(ctx, H.doneAtHome(ctx), 6 * 3600, "3 corridors then DONE")
        H.commonChecks(ctx)
        local TY = ctx.worldTargetY
        local lastC, mains = -1, {}
        for _, d in ipairs(H.dugGrid(ctx)) do
            if d.y >= TY - 1 and d.y <= TY + 2 and d.f >= 2 then
                local c = math.floor((d.r + W / 2) / W)
                H.check(math.abs(d.r - c * W) <= BL, "dug cell f=%d r=%d is outside every corridor footprint (W=%d)", d.f, d.r, W)
                H.check(c >= lastC, "dug corridor %d's cell f=%d r=%d after corridor %d had started", c, d.f, d.r, lastC)
                lastC = c
                if d.r == c * W then mains[c] = (mains[c] or 0) + 1 end
            end
        end
        for c = 0, 2 do
            H.check((mains[c] or 0) >= ctx.cfg.MAIN_LENGTH - 2, "corridor %d main barely dug (%d cells)", c, mains[c] or 0)
        end
        H.check(ctx.w.digLog[#ctx.w.digLog] and true, "nothing dug")
        return "3 corridors at r=0," .. W .. "," .. 2 * W
    end,
}
