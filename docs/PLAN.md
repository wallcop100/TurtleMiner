# TurtleMiner Fix Plan

Status tracking lives in [TRACKING.md](TRACKING.md). This file is the design; that file is the source of truth for progress. If they disagree, TRACKING.md wins and this file gets corrected.

## 1. Goal

A miner that:
- survives server restarts and chunk unloads without anyone at the keyboard
- never loses its position or facing
- obeys monitor commands, and only the ones meant for it
- tells you clearly when it's stuck and why
- installs in one command and is configured from one file

## 2. Root causes (from the review)

| # | Problem | Where | Fixed by |
|---|---------|-------|----------|
| R1 | Facing never saved on turns | `miner_movement.lua` turnLeft/turnRight | WP-A |
| R2 | Position saved after the move, not before | `miner_movement.lua`, `miner_core.lua:232` | WP-A |
| R3 | Position file written in place, a crash mid-write corrupts it, then the turtle assumes it's at home | `miner_persistence.lua`, `miner_core.lua:466` | WP-A |
| R4 | GPS facing probe silently defaults to north if blocked | `miner_core.lua:288` | WP-A |
| R5 | Blocking `read()` prompts after every reboot (settings, no chest, full chest) | `miner_core.lua:585`, `miner_inventory.lua` | WP-C, WP-B |
| R6 | Command listener killed after 1s | `miner_core.lua:753` | WP-C |
| R7 | Branch listener compares a table to the string `"RETURN_HOME"` | `miner_mining.lua:662` | WP-B |
| R8 | `REQUEST_STATUS` calls a function that doesn't exist | `miner_core.lua:206` | WP-C |
| R9 | Monitor broadcasts commands with no target ID, so every turtle obeys every command | `central_monitor.lua:353` | WP-D |
| R10 | Return-home runs in a second coroutine while mining still moves the turtle | `miner_core.lua:861` | WP-C |
| R11 | No refuel after startup; coal dumped into the chest; `FUEL_THRESHOLD` unused | `miner_inventory.lua`, `miner_mining.lua` | WP-B |
| R12 | "New corridor" is always 6 blocks from home, on top of old branches | `miner_mining.lua:719` | WP-B |
| R13 | `returnHome()` failure ignored; then dumps into rock / floor | many call sites | WP-B, WP-C |
| R14 | `safeForward` gives up after 10 tries (gravel columns end corridors) | `miner_movement.lua` | WP-A |
| R15 | A broadcast and 2 file writes per block; the monitor replies to each one | `miner_core.lua:232`, monitor | WP-C, WP-D |
| R16 | Updater runs mid-job, rewrites `startup`, reboots despite `--no-reboot`, crashes on non-table reply | `turtle_updater.lua` | WP-E |
| R17 | Duplicate/old copies (`old/`, `miner/260216/`, `servers/update sever/`) make it easy to deploy the wrong file | repo | WP-E |

## 3. Target design

### 3.1 Turtle file layout (all flat, CC has no package dirs by default)

| File | Owner WP | Purpose |
|------|----------|---------|
| `miner/config.lua` | WP-C | Defaults. User overrides in `miner.cfg` (settings API), not by editing code |
| `miner/state.lua` | WP-A | Atomic save/load of all persistent state |
| `miner/nav.lua` | WP-A | Moves, turns, facing, journal, GPS correction, `goTo` |
| `miner/inv.lua` | WP-B | Refuel, fuel reserve, dump, storage detection |
| `miner/mine.lua` | WP-B | Branch pattern, vein mining, corridor counter |
| `miner/net.lua` | WP-C | Single rednet wrapper, message schema, command inbox |
| `miner/miner.lua` | WP-C | Main: boot, state machine, coroutines |
| `miner/startup.lua` | WP-E | `shell.run("miner")`, nothing else |
| `miner/install.lua` | WP-E | One-shot installer + first-time config |
| `miner/updater.lua` | WP-E | Replaces `turtle_updater.lua`; only runs at boot or when idle at home |

### 3.2 Persistence (WP-A)

- One file `.miner_state`. Write to `.miner_state.tmp`, then `fs.delete` + `fs.move`. On load, if main is missing/corrupt but `.tmp` is valid, use `.tmp`.
- State holds: `pos`, `facing`, `home`, `homeFacing`, `phase`, `corridor`, `branch`, `branchStep`, `pending`, `settings`, `stats`.
- **Journal before move:** before calling `turtle.forward/up/down/back/turn*`, save `pending = {op, from=pos, fromFacing}`. After success, apply and clear `pending` in the same save. On boot, if `pending` is set, resolve it:
  - GPS available → use GPS position (and a GPS probe for facing).
  - No GPS, move op → check `turtle.getFuelLevel()` against the `fuel` recorded in `pending`. If fuel dropped by 1, the move happened.
  - Turn op → turns use no fuel, so without GPS: `pending` also stores the `turtle.inspect()` result for the block in front before the turn and the block expected after it. On boot, inspect again; if it matches only one of the two, that settles it. If it matches both or neither, report `NEEDS_HELP` (no silent guess).
- Settings are not prompted at boot. They come from `miner.cfg` (via `settings` API) and are changed via `install` or monitor commands.

### 3.3 Navigation (WP-A)

- `nav.forward/up/down(digFn)`: retry loop with dig + attack, **no attempt cap for gravel/sand/mobs**. Gives up only on: unbreakable block (`turtle.dig` returns false with "Unbreakable block"), out of fuel, or 60s with no progress. Returns `ok, reason`.
- `nav.goTo(target, opts)`: axis order configurable; for return-home: X/Z at current Y through own tunnels, then Y. Returns `ok, reason`. On failure tries the other axis order once before giving up.
- `nav.face(dir)` picks the shortest turn.
- GPS: if available, re-sync position at boot and before every return home; if GPS disagrees with dead reckoning, trust GPS and log an event.
- Facing probe: try forward, back, up+forward; if all blocked, report `NEEDS_HELP` instead of guessing.
- Hook `nav.onMove(pos)` used by main for throttled status (no per-block broadcast).

### 3.4 Inventory and fuel (WP-B)

- Fuel slot reserve: keep up to 1 stack of the best fuel (coal/charcoal/blaze rod/lava bucket handling skipped) in slot 16; never dumped.
- `inv.refuelFromInventory(target)`: burn mined coal until `target` fuel, keeping the reserve.
- Required fuel to continue = `distHome * 1.5 + FUEL_THRESHOLD`. Checked every step; triggers `RETURNING(reason="fuel")`.
- At home: dump everything except reserve; then try `turtle.suck` from a configured fuel chest (optional `FUEL_CHEST` side) to top up.
- Dump never prompts. Chest full or missing → phase `NEEDS_HELP` with reason, retry every 30s, keep reporting.
- Junk filter (optional, config `TRASH`): cobble/deepslate/dirt/gravel/tuff dropped in the tunnel when inventory is near full, so trips home are fewer.

### 3.5 Mining pattern (WP-B)

- Grid defined relative to home + `homeFacing`, stored as `corridor` (int) and `branch` (int), `branchStep` (int). Corridor N starts at `CORRIDOR_SPACING * N` along the main axis; never reused. Corridor count persists.
- Resume = `nav.goTo(branchStart(corridor, branch))` then continue at `branchStep`. No re-walking from scratch, no re-descending in the same column every time beyond the shaft.
- One shaft at home X/Z down to `TARGET_Y`; all trips use it.
- Vein mining: iterative (explicit stack) not recursive, treats `deepslate_X_ore` and `X_ore` as the same vein, capped by `VEIN_MAX`. Returns via `nav.goTo` of the start point.
- `MAX_CORRIDORS` / `MAX_DISTANCE` config to stop cleanly instead of wandering forever.
- The mining loop calls `ctl.check()` between every step (see 3.6); it never listens to rednet itself.

### 3.6 Main / control (WP-C)

Two coroutines only:
1. **worker**: the only code that moves the turtle. A state machine: `BOOT → RESYNC → GO_TO_WORK → MINING → RETURNING → UNLOADING → (GO_TO_WORK | IDLE | NEEDS_HELP)`.
2. **net**: receives rednet, filters by `to == os.getComputerID()` (or `to == "all"`), pushes to an inbox, ACKs. Sends status every `STATUS_INTERVAL` seconds and immediately on phase change.

`ctl.check()` (called by worker between steps) drains the inbox and sets flags: `RETURN_HOME`, `PAUSE`, `RESUME`, `SET_TARGET_Y`, `FOCUS_ORE`, `STOP`, `UPDATE` (update only applied while at home and IDLE). No movement in the net coroutine, ever.

Whole worker wrapped in `xpcall` with traceback. On error: save state, report `ERROR` + traceback (first 200 chars), try to return home once, then `NEEDS_HELP`. Never sits on a `read()`.

### 3.7 Network protocol (contract; WP-0 writes it, WP-C and WP-D implement it)

Single protocol `TMINER`. Every message: `{v=1, kind=..., from=id, to=id|"all"|"server", ts=os.epoch("utc"), seq=n, ...}`.

| kind | direction | fields |
|------|-----------|--------|
| `status` | turtle→server | `label, phase, reason, pos, facing, home, fuel, fuelNeeded, slotsUsed, corridor, branch, ores, gps, lastError, version` |
| `event` | turtle→server | `text`, `level` (info/warn/error) |
| `cmd` | server→turtle | `cmd, params, id` |
| `ack` | turtle→server | `id`, `ok`, `err` |
| `hello` | turtle→server, boot | `version, config` summary |
| `home_save` / `home_get` / `home` | both | kept from today for recovery when the local file is lost |

- Status every 10s plus on phase change. No per-block messages. Mined-area DB gets a batch `mined` message every 30s with the block list since last send (optional, behind `REPORT_MINED=false` default).
- Relaying: only servers relay (turtles don't), dedup by `(from, seq)`.

### 3.8 Monitor (WP-D)

- Speaks the `TMINER` protocol only (old protocols dropped after cut-over).
- Commands addressed to one turtle; ACK wait is non-blocking (pending table, retried 3x, shown on the card).
- Turtle card shows: phase (coloured), reason, fuel vs needed, distance home, last seen, last error.
- Alerts: `NEEDS_HELP`, `ERROR`, or no status for 60s → card turns red, list sorts problem turtles to the top, optional speaker beep.
- Keeps the touchscreen UI; terminal fallback when no monitor attached.
- Log file `miner_events.log` (rotating, 500 lines) so you can see what happened while you were away.
- `servers/startup.lua`: the bridge and the monitor run together with `parallel.waitForAll`, peripheral sides from a config at the top.

### 3.9 Install / update (WP-E)

- `install.lua` on a fresh turtle: checks modem/pickaxe/fuel, asks 4 questions once (label, target Y, storage side, ore focus), writes `miner.cfg` + `startup.lua`. Can also be fed via `install --default`.
- Updater: run at boot only (and on `UPDATE` cmd when idle at home). Validates each file with `load` before swapping. One reboot max. Never rewrites `startup.lua` unless it's missing.
- Update server: one manifest of files with versions; moved to `servers/update_server/`.
- Cleanup: delete `old/`, `miner/260216/`, the old `miner/*.lua` modules, and `servers/update sever/`. `farmer/` untouched.

### 3.10 Testing (WP-T)

- Headless simulator `test/sim/` in plain Lua 5.2+: fake `turtle`, `fs`, `os`, `rednet`, `gps`, `peripheral`, `settings`, world grid with ores/bedrock/gravel/chest. Can "crash" at a chosen point (throw between journal write and move, or mid-file-write).
- Scenarios (each a test file):
  1. Fresh start, mines 2 corridors, unloads, no prompts.
  2. Crash after each kind of op (forward, up, down, turn, mid-save) → reboot → position + facing correct (with and without GPS).
  3. Gravel column of 20 in the path → not treated as stuck.
  4. Bedrock / unbreakable → `NEEDS_HELP` with reason, no infinite loop.
  5. Low fuel → returns, refuels from coal, continues; never strands (fuel never hits 0 away from home).
  6. Chest full → `NEEDS_HELP`, resumes when space appears.
  7. Command for turtle 5 ignored by turtle 6; RETURN_HOME mid-vein returns cleanly.
  8. Corridor N+1 never overlaps corridor N.
- If no Lua interpreter is available in the container, WP-T installs one (`apt-get install lua5.4`), or falls back to `luac -p` syntax checks plus manual review. Recorded in TRACKING.md either way.
- Final step is an in-game checklist for you (TRACKING.md section "In-game acceptance").

## 4. Work packages and agents

Each WP owns its files; no two parallel agents edit the same file. Agents work in separate git worktrees off `claude/vigilant-pasteur-g2krss`; the coordinator (main session) merges, runs tests, updates TRACKING.md.

| WP | Agent | Depends on | Owns |
|----|-------|-----------|------|
| WP-0 Contracts | coordinator | none | `docs/PROTOCOL.md`, `docs/INTERFACES.md` (function signatures for state/nav/inv/mine/net), `miner/config.lua` skeleton |
| WP-T Simulator | agent 1 | WP-0 | `test/**` |
| WP-A State + Nav | agent 2 | WP-0 | `miner/state.lua`, `miner/nav.lua` |
| WP-B Inv + Mine | agent 3 | WP-0 | `miner/inv.lua`, `miner/mine.lua` |
| WP-C Net + Main | agent 4 | WP-0 | `miner/net.lua`, `miner/miner.lua`, `miner/config.lua` |
| WP-D Monitor | agent 5 | WP-0 | `servers/central_monitor.lua`, `servers/startup.lua` |
| WP-E Install/Update/Cleanup | agent 6 | WP-0 | `miner/install.lua`, `miner/updater.lua`, `miner/startup.lua`, `servers/update_server/**`, archive moves |
| WP-I Integration | coordinator | A–E, T | wiring fixes, scenario runs |
| WP-R Review | agent 7 (code-review) | WP-I | review findings → fixes |
| WP-G In-game test | you | WP-R | checklist in TRACKING.md |

Order: WP-0 → (WP-T, A, B, C, D, E in parallel) → WP-I → WP-R → WP-G.

Rules for every agent:
- Read `docs/PLAN.md`, `docs/INTERFACES.md`, `docs/PROTOCOL.md` first.
- Stay within owned files. If an interface must change, stop and report it; the coordinator changes WP-0 docs and tells the others.
- No `read()` anywhere except `install.lua`.
- Every file starts with `-- Version: x.y.z`.
- Return: files changed, which root causes (R#) are addressed, open issues. The coordinator copies this into TRACKING.md.

## 5. Decisions (answered 2026-10-31)

| ID | Question | Answer |
|----|----------|--------|
| D1 | Rewrite vs patch | Rewrite |
| D2 | GPS | Must work with and without, decided per turtle at runtime |
| D3 | Old copies | Delete `old/`, `miner/260216/`, old `miner/*.lua` modules, `servers/update sever/`. `farmer/` stays |
| D4 | Monitor | Keep touchscreen, and also run on a pocket computer (phone-sized layout) |
| D5 | Old protocol compatibility | None, clean break |
| D6 | Fuel chest | Auto-detect: works with a fuel chest, without one, or with unlimited fuel |

## 6. Changes after decisions

- **Crash recovery uses a move journal, not just a snapshot.** CC writes turtle files to disk instantly, but the world saves every few minutes. After a server crash (not a clean stop) the world can roll back several moves while the files don't. Each move costs exactly 1 fuel, so the journal records fuel after every op and recovery matches the world's real fuel to the right journal entry. GPS, when present, overrides. Details in INTERFACES.md (state, nav).
- **Mining grid** is a spine + mains + branches layout in the home frame so nothing overlaps and any job step can be resumed by coordinates. Details in INTERFACES.md (mine).
- **Pocket monitor**: the same `central_monitor.lua` detects a pocket computer and runs in remote mode, using `fleet` snapshots the server broadcasts. Layout must fit 26x20.
- **Mined-area DB dropped** (per-block traffic was a root cause; nothing used it for decisions).
- **Server relay** replaces the separate wired/wireless bridge script: any server with several modems relays `TMINER` messages with dedupe and a hop limit.
- Lua 5.4 is installed in the container for the simulator. CC runs Cobalt (Lua 5.2 semantics): no `//`, no bitwise operators, no `<const>`/`<close>`, no integer/float assumptions (`math.floor` everything that's a coordinate).

