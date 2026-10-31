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
| WP-B Inv + Mine | agent 3 | DOING | agent worktree | | |
| WP-C Net + Main | agent 4 | DOING | agent worktree | | |
| WP-D Monitor | agent 5 | DOING | agent worktree | | |
| WP-E Install / Update / Cleanup | agent 6 | DONE | merged | 88aa268 (cherry-picked) | 37 throwaway tests pass. Deviations: updater called via require().run not shell.run; seq starts random; all-or-nothing updates; installer asks label/Y/focus/corridors (storage auto-detected) |
| WP-I Integration | coordinator | TODO | | | |
| WP-R Code review | agent 7 | TODO | | | |
| WP-G In-game acceptance | you | TODO | | | |

## Root causes

| # | Short | WP | Status | Verified by |
|---|-------|----|--------|-------------|
| R1 | Facing not saved on turns | A | DONE (unit) | scenario 2 |
| R2 | Save after move, not before | A | DONE (unit) | scenario 2 |
| R3 | Non-atomic save, corrupt → assumes home | A | DONE (unit) | scenario 2 |
| R4 | GPS facing probe guesses north | A | DONE (unit) | scenario 2 (GPS) |
| R5 | Blocking prompts after reboot | B, C | TODO | scenario 1, 6 |
| R6 | Command listener killed after 1s | C | TODO | scenario 7 |
| R7 | Branch listener string vs table | B | TODO | scenario 7 |
| R8 | REQUEST_STATUS crash | C | TODO | scenario 7 |
| R9 | Commands not addressed to one turtle | D | TODO | scenario 7 |
| R10 | Two coroutines moving the turtle | C | TODO | scenario 7 |
| R11 | Fuel: no refuel, coal dumped, threshold unused | B | TODO | scenario 5 |
| R12 | New corridor overlaps old | B | TODO | scenario 8 |
| R13 | returnHome failure ignored | B, C | TODO | scenario 4 |
| R14 | Gives up after 10 tries | A | DONE (unit) | scenario 3 |
| R15 | Per-block network + disk spam | C, D | TODO | review |
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

## In-game acceptance (you)

- [ ] `install` on a fresh turtle finishes with no code edits
- [ ] Turtle mines, unloads, goes back to where it was
- [ ] `/stop` or leave the chunk mid-tunnel, come back: turtle resumes on its own, right spot, right facing
- [ ] Kill the server process (not /stop) mid-tunnel, restart: turtle recovers position
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
