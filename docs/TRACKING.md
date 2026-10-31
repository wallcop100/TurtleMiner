# TurtleMiner Fix Tracker

Design: [PLAN.md](PLAN.md). This file is the single source of truth for progress. Update it at the end of every work session and after every agent returns.

Status key: `TODO` · `DOING` · `BLOCKED` · `REVIEW` · `DONE`

## Decisions

| ID | Question | Answer | Status |
|----|----------|--------|--------|
| D1 | Rewrite vs patch | Default: rewrite | waiting on you |
| D2 | GPS at the mine? | Default: optional | waiting on you |
| D3 | Delete or archive old copies | Default: archive | waiting on you |
| D4 | Keep touchscreen monitor | Default: yes | waiting on you |
| D5 | Old protocol compatibility | Default: no | waiting on you |
| D6 | Fuel chest at home | Default: optional, off | waiting on you |

## Work packages

| WP | Owner | Status | Branch / worktree | Commit | Notes |
|----|-------|--------|-------------------|--------|-------|
| WP-0 Contracts (PROTOCOL.md, INTERFACES.md, config skeleton) | coordinator | TODO | main branch | | |
| WP-T Simulator + scenarios | agent 1 | TODO | | | Check for a Lua interpreter first |
| WP-A State + Nav | agent 2 | TODO | | | |
| WP-B Inv + Mine | agent 3 | TODO | | | |
| WP-C Net + Main | agent 4 | TODO | | | |
| WP-D Monitor | agent 5 | TODO | | | |
| WP-E Install / Update / Cleanup | agent 6 | TODO | | | |
| WP-I Integration | coordinator | TODO | | | |
| WP-R Code review | agent 7 | TODO | | | |
| WP-G In-game acceptance | you | TODO | | | |

## Root causes

| # | Short | WP | Status | Verified by |
|---|-------|----|--------|-------------|
| R1 | Facing not saved on turns | A | TODO | scenario 2 |
| R2 | Save after move, not before | A | TODO | scenario 2 |
| R3 | Non-atomic save, corrupt → assumes home | A | TODO | scenario 2 |
| R4 | GPS facing probe guesses north | A | TODO | scenario 2 (GPS) |
| R5 | Blocking prompts after reboot | B, C | TODO | scenario 1, 6 |
| R6 | Command listener killed after 1s | C | TODO | scenario 7 |
| R7 | Branch listener string vs table | B | TODO | scenario 7 |
| R8 | REQUEST_STATUS crash | C | TODO | scenario 7 |
| R9 | Commands not addressed to one turtle | D | TODO | scenario 7 |
| R10 | Two coroutines moving the turtle | C | TODO | scenario 7 |
| R11 | Fuel: no refuel, coal dumped, threshold unused | B | TODO | scenario 5 |
| R12 | New corridor overlaps old | B | TODO | scenario 8 |
| R13 | returnHome failure ignored | B, C | TODO | scenario 4 |
| R14 | Gives up after 10 tries | A | TODO | scenario 3 |
| R15 | Per-block network + disk spam | C, D | TODO | review |
| R16 | Updater misbehaves | E | TODO | review + in-game |
| R17 | Duplicate old copies | E | TODO | review |

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

## In-game acceptance (you)

- [ ] `install` on a fresh turtle finishes with no code edits
- [ ] Turtle mines, unloads, goes back to where it was
- [ ] `/stop` or leave the chunk mid-tunnel, come back: turtle resumes on its own, right spot, right facing
- [ ] RETURN_HOME from the monitor affects only the chosen turtle
- [ ] Fill the chest: monitor shows NEEDS_HELP with the reason; empty it: turtle carries on
- [ ] Run it until fuel gets low: it comes home, refuels, continues
- [ ] Unplug the monitor server for a while: turtles keep mining; it catches up when back
- [ ] Push an update from the update server: turtles take it at home, one reboot

## Log

| Date | Who | What |
|------|-----|------|
| 2026-10-31 | coordinator | Review done, PLAN.md + TRACKING.md written. Waiting on decisions D1–D6 before WP-0. |
