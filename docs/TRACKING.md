# TurtleMiner Fix Tracker

Design: [PLAN.md](PLAN.md). This file is the single source of truth for progress. Update it at the end of every work session and after every agent returns.

Status key: `TODO` · `DOING` · `BLOCKED` · `REVIEW` · `DONE`

## Decisions

| ID | Question | Answer | Status |
|----|----------|--------|--------|
| D1 | Rewrite vs patch | Rewrite | DONE |
| D2 | GPS | With and without, per turtle at runtime | DONE |
| D3 | Old copies | Delete (farmer/ stays) | DONE |
| D4 | Monitor | Touchscreen + pocket computer layout | DONE |
| D5 | Old protocol compatibility | None | DONE |
| D6 | Fuel chest | Auto-detect any setup | DONE |

## Work packages

| WP | Owner | Status | Branch / worktree | Commit | Notes |
|----|-------|--------|-------------------|--------|-------|
| WP-0 Contracts (PROTOCOL.md, INTERFACES.md, config skeleton) | coordinator | DONE | claude/vigilant-pasteur-g2krss | see log | config.lua written by coordinator; WP-C owns it from here |
| WP-T Simulator + scenarios | agent 1 | DOING | agent worktree | | Lua 5.4 installed via apt (not persisted across sessions: `apt-get install -y lua5.4`) |
| WP-A State + Nav | agent 2 | DONE | merged | 52fd13c (cherry-picked) | 63 throwaway checks pass. Additions: nav.init opts.cfg/onEvent, nav self-snapshots every SNAPSHOT_EVERY, st.lost/st.facingUnknown, S journal line has 7th field. Turn crash without GPS → NEEDS_HELP (inspect heuristic from PLAN not built). Unlimited fuel without GPS can't detect rollback. |
| WP-B Inv + Mine | agent 3 | DONE | merged | 0f9637d (cherry-picked) | 67 throwaway checks pass. Additions: st.job.geom (grid frozen per job), mine.retreat(), vein returns count,signal,reason, ctl.event optional, c:ores/forge:ores tags count as ore. |
| WP-C Net + Main | agent 4 | DONE | merged | 2ff1bd3 (cherry-picked) | 42 stub-harness checks pass; not yet run with real nav/mine. Accepted deviations: RESET_HOME while lost sets pos=home (keeps job); GPS first boot prefers server home record; net.setValidator added; st.flags.afterHome; SET string values coerced. |
| WP-D Monitor | agent 5 | DONE | merged | e2cbc83 (cherry-picked) | 69 throwaway checks pass incl. render fuzz 1x1..164x81. central_monitor.lua ~1085 lines (over guideline, accepted). Protocol gaps fixed by coordinator: fleet id, ack forwarding fields, home_get prefers found=true, FOCUS values documented. |
| WP-E Install / Update / Cleanup | agent 6 | DONE | merged | 88aa268 (cherry-picked) | 37 throwaway tests pass. Deviations: updater called via require().run not shell.run; seq starts random; all-or-nothing updates; installer asks label/Y/focus/corridors (storage auto-detected) |
| WP-I Integration | coordinator | DOING | claude/vigilant-pasteur-g2krss | | Done so far: goHome calls mine.retreat first; HOME_Y config + installer question for no-GPS turtles; SET HOME_Y shifts relative frame; ctl.event wired; README/installer say chest not below home. Waiting on WP-T to run scenarios. |
| WP-R Code review | agent 7 | TODO | | | |
| WP-G In-game acceptance | you | TODO | | | |

## Root causes

| # | Short | WP | Status | Verified by |
|---|-------|----|--------|-------------|
| R1 | Facing not saved on turns | A | DONE (unit) | scenario 2 |
| R2 | Save after move, not before | A | DONE (unit) | scenario 2 |
| R3 | Non-atomic save, corrupt → assumes home | A | DONE (unit) | scenario 2 |
| R4 | GPS facing probe guesses north | A | DONE (unit) | scenario 2 (GPS) |
| R5 | Blocking prompts after reboot | B, C | DONE (unit) | scenario 1, 6 |
| R6 | Command listener killed after 1s | C | DONE (unit) | scenario 7 |
| R7 | Branch listener string vs table | B | DONE (unit) | scenario 7 |
| R8 | REQUEST_STATUS crash | C | DONE (unit) | scenario 7 |
| R9 | Commands not addressed to one turtle | D | DONE (unit) | scenario 7 |
| R10 | Two coroutines moving the turtle | C | DONE (unit) | scenario 7 |
| R11 | Fuel: no refuel, coal dumped, threshold unused | B | DONE (unit) | scenario 5 |
| R12 | New corridor overlaps old | B | DONE (unit) | scenario 8 |
| R13 | returnHome failure ignored | B, C | DONE (unit) | scenario 4 |
| R14 | Gives up after 10 tries | A | DONE (unit) | scenario 3 |
| R15 | Per-block network + disk spam | C, D | DONE (unit) | review |
| R16 | Updater misbehaves | E | DONE | WP-E tests; in-game pending |
| R17 | Duplicate old copies | E | DONE | WP-E tests; in-game pending |

## Test scenarios (simulator)

| # | Scenario | Status | Last result |
|---|----------|--------|-------------|
| 1 | Fresh start, 2 corridors, unload, no prompts | TODO | |
| 2 | Crash after each op type, reboot, position + facing correct (GPS / no GPS) | TODO | |
| 3 | 20-high gravel column not treated as stuck | TODO | |
| 4 | Bedrock → NEEDS_HELP, no loop | TODO | |
| 5 | Low fuel → return, refuel, continue, never strands | TODO | |
| 6 | Chest full → NEEDS_HELP, resumes when emptied | TODO | |
| 7 | Commands addressed correctly; RETURN_HOME mid-vein | TODO | |
| 8 | Corridors never overlap | TODO | |
| 9 | World rollback after crash (state ahead of world by N moves) recovered via fuel journal | TODO | |
| 10 | Pocket layout renders in 26x20 without overflow | TODO | |
| 11 | Deepslate transition: stone/deepslate variants one vein, cobbled_deepslate is trash | TODO | |
| 12 | Jagged bedrock (-64..-60): downward vein stops at bedrock, run continues | TODO | |
| 13 | Caves and ravines crossed: no stuck, wall ores found, position exact | TODO | |
| 14 | Lava aquifers below Y -55 and water aquifers: fluids passed, not stuck | TODO | |
| 15 | Amethyst geodes + falling pointed dripstone: no stuck, not ore, trash list gaps reported | TODO | |
| 16 | Raw ore drops fill inventory mid-vein: backtrack, unload, resume at right step | TODO | |
| 17 | Large iron/copper ore veins: raw_*_block is ore, VEIN_MAX stops cleanly, filler is trash | TODO | |
| 18 | 1.18 ore heights: FOCUS diamond at -58; SET TARGET_Y 16 + iron mid-job | TODO | |
| 19 | Cliffs: home at Y 150, 208-block shaft, exact fuel, never strands; negative HOME_Y | TODO | |
| 20 | Cave mobs (leave vs never leave → timeout NEEDS_HELP) and buried ore found | TODO | |

## In-game acceptance (you)

- [ ] `install` on a fresh turtle finishes with no code edits
- [ ] Turtle mines, unloads, goes back to where it was
- [ ] `/stop` or leave the chunk mid-tunnel, come back: turtle resumes on its own, right spot, right facing
- [ ] Kill the server process (not /stop) mid-tunnel, restart: turtle recovers position
- [ ] Mine at Y -58 near lava lakes: turtle passes lava without getting stuck (watch the monitor)
- [ ] Home on a mountain (Y > 100): turtle gets down and back with fuel to spare
- [ ] Pocket computer shows the fleet and can send commands
- [ ] RETURN_HOME from the monitor affects only the chosen turtle
- [ ] Fill the chest: monitor shows NEEDS_HELP with the reason; empty it: turtle carries on
- [ ] Run it until fuel gets low: it comes home, refuels, continues
- [ ] Unplug the monitor server for a while: turtles keep mining; it catches up when back
- [ ] Push an update from the update server: turtles take it at home, one reboot

## Log

| Date | Who | What |
|------|-----|------|
| 2026-10-31 | coordinator | Review done, PLAN.md + TRACKING.md written. Waiting on decisions D1–D6 before WP-0. |
| 2026-10-31 | coordinator | Decisions D1–D6 answered. Plan updated (journal recovery, grid, pocket monitor). Starting WP-0. |
| 2026-10-31 | coordinator | WP-0 done: PROTOCOL.md, INTERFACES.md, miner/config.lua. Launched agents for WP-T, A, B, C, D, E in parallel worktrees. |
| 2026-10-31 | coordinator | WP-E merged. Told WP-A to keep .tm_state/journal format WP-E reads; told WP-C to use require("updater").run and random seq start. |
| 2026-10-31 | coordinator | WP-A merged. Sent WP-C the nav additions (onEvent, st.lost cleared by RESET_HOME, nav self-snapshots). |
| 2026-10-31 | coordinator | WP-C merged. Deviations accepted (RESET_HOME while lost = 'turtle is at home now'). |
| 2026-10-31 | coordinator | WP-B merged. Integration fixes from WP-B's notes: retreat before goTo home, no-GPS turtles used home Y=0 while TARGET_Y is world Y (added HOME_Y), chest-below-home conflict documented + installer warning. |
| 2026-10-31 | coordinator | WP-D merged. net.request now prefers found=true home replies across servers; PROTOCOL.md updated with WP-D's gaps. Only WP-T outstanding. |
| 2026-10-31 | coordinator | Scenarios doubled to 20 with 1.18+ Caves & Cliffs cases (deepslate, jagged bedrock, caves, lava/water aquifers, geodes, dripstone, raw ore drops, large ore veins, ore heights, tall terrain, cave mobs). Sent to WP-T. |
