# Turtle Army Plan (phase 2)

Starts after the review fixes (WP-F) and your in-game test are done. Progress is tracked in [TRACKING.md](TRACKING.md) under "Army".

## Scope (your answers, 2026-10-31)

| Topic | Decision |
|-------|----------|
| Fleet size | 4–20 turtles |
| Traffic | Reservations in 1-wide tunnels |
| Unloading | One shared chest station |
| GPS | Any or none: detected at runtime. Optional underground GPS nodes for setups whose hosts can't reach depth |
| Bridge | Both: turtles relay **automatically** (no setting needed), plus fixed relay computers |
| Chunk loading | None; player is nearby |
| Solo turtles | Keep working; easy to join into a group |
| Order | After the current fixes and in-game test |

## Comms constraint (see COMMS.md)

Basic modems reach 64 blocks, so with no ender modem turtles only talk to the master near home. Rules for the army:
- Branch claims and the **down** shaft reservation are handed out at the shaft top.
- The **up** reservation needs contact at the bottom: a relay at the shaft bottom, any ender modem in the network (hub), or, with neither, **timed slots** agreed before leaving (turtle gets "up-shaft window at T+n min"; it waits at the bottom until its window).
- Turtle-to-turtle relaying helps only within 64 blocks and is never relied on.

## How it works

### 1. Groups
- A group = one shared station (shaft top, loot chest, optional fuel chest) + one shared grid. Stored on the server, not on turtles.
- Setting `tminer.GROUP` (empty = solo, same as today). `JOIN <group>` / `LEAVE` commands from the monitor, or `install --group <name>`.
- Joining: the turtle drops its solo job (progress kept in case it leaves again), goes home, then goes to the group station. With a GPS fix it walks there; without GPS the monitor tells you to carry it to the station and press RESET_HOME there.

### 2. Coordinator (on the server)
- New module in the server: owns each group's grid (same layout as today: shaft, spine, corridors, branches).
- Hands out **branch claims** (`corridor, branch, side`) to turtles that ask. A turtle mines only its claimed branch, reports progress, asks for the next.
- **Nothing held by a silent turtle is reassigned automatically.** With no chunk loaders, a silent turtle is usually just unloaded and still physically in its tunnel; sending another turtle there would block both. You release it with a `RELEASE <turtle>` command once you've found it.
- The grid is kept compact by default (`GROUP_RADIUS`, default 64 blocks from the shaft) so it stays inside the area loaded around the player and inside underground GPS range (section 4).

### 3. Traffic reservations
- Shared lanes are split into **segments**: the shaft (one segment per 16 blocks), the spine and each corridor main (16-block segments). Branches don't need locks: each is owned by one claim.
- A turtle asks the coordinator for the segments ahead before entering, holds them while inside, releases behind it.
- **Direction locks, not one-at-a-time:** a segment can hold several turtles going the same way (a convoy). It flips direction only when empty. Without this a 1-wide, ~200-block shaft would be the bottleneck at 20 turtles (one trip each way takes about 80 s).
- Turtles never dig or attack another turtle (already true after WP-F). If one is in the way despite the locks, the turtle waits, reports `WAITING` with the blocker's ID, and after a timeout goes `NEEDS_HELP`.
- Server offline → turtles finish the segment they're in and wait at the next lane entry (no movement through shared lanes without a reservation).

### 4. GPS underground
- **GPS can't be relayed over rednet.** A fix is worked out from how far away each host's reply came from, so relayed replies give wrong positions. Turtles without ender modems therefore need GPS hosts within wireless range (about 64 blocks underground, less in storms).
- **GPS nodes:** 4 computers with wireless modems, placed by you near the shaft bottom at mining depth, spread out and not all on one level. New program `gpsnode`:
  - gets its own position from your surface GPS (attach an ender modem once, or it asks you to type the coordinates from F3),
  - saves it and runs `gps host` on boot,
  - reports its health to the server (the monitor shows "GPS nodes 4/4").
- `setup.lua gpsnode` installs it.
- With every turtle in GPS range, crash recovery becomes reliable (position from GPS, facing from a one-block probe). This also closes the remaining "facing unknown after crash" gap.

### 5. Bridge mode (both)
- **Turtle relay (automatic, every turtle):** each turtle keeps its hop distance to the server: 0 hops if it heard the server directly in the last 30 s, otherwise 1 + the lowest distance it hears from other turtles (distance is carried in every message). A turtle relays a message only if that moves it closer to where it's going: upward traffic if its distance is lower than the sender's, server traffic if its distance is lower than the recipient's last known distance. Same dedupe + hop limit as the server, plus a small random delay. This keeps 20 turtles from all rebroadcasting everything. Ender-modem turtles naturally end up as the 0-hop gateways. `tminer.RELAY=false` turns it off for a turtle.
- **Fixed relays:** new small `relay` program (the relay part of `central_monitor`, no UI). `setup.lua relay` installs it. Place one at the shaft bottom; a GPS node computer can run it as well.
- The monitor shows each turtle's path to the server (direct / via relay N / via turtle N).

### 6. Shared chest station
- Station = shaft top. Loot chest and optional fuel chest beside it (same detection as today).
- Unloading is part of the shaft reservation: the turtle at the top unloads, refuels, then joins the next down convoy. Others queue in the shaft below and wait.
- A full chest → every turtle in the group waits at the station and the monitor shows one alert for the group, not 20.

### 7. Monitor
- Group view: claim map (which turtle is on which branch), lane segments and their direction, the queue at the station, GPS node health, relay paths.
- Commands: JOIN, LEAVE, RELEASE, PAUSE GROUP, RETURN GROUP.
- Pocket: group summary page + the existing per-turtle pages.

## Work packages

Already done elsewhere (not army work any more): bridge/relay (COMMS CM-5), GPS hosting and offer (CLUSTER_GPS CG-3/4), mesh updates (MU). The army builds on them.

| WP | What | Files (owner) |
|----|------|---------------|
| AR-0 | Protocol + interfaces: `group_join/leave`, `claim_req/grant/done/release`, `seg_req/grant/release`, `slot` (timed shaft window), `station_q`; group record format; turtle-side `group` API | `docs/PROTOCOL.md`, `docs/INTERFACES.md` |
| AR-1 | Coordinator on the leader: group records, shared grid (reuses mine.lua's layout maths), branch claims, segment locks with direction/convoys, timed up-shaft slots, station queue, replicated through the cluster DB, "never reassign a silent turtle" + RELEASE | new `servers/tm_army.lua`; 1 hook each in `tm_radio.lua` (message branch) and `tm_db.lua` (replicated table) |
| AR-2 | Turtle group mode: settings `GROUP`, ask for a claim at the station, mine only that branch, ask for segments before shared lanes (shaft/spine/mains), wait/queue, use slots when out of contact, join/leave, overlap check + right of way for solo turtles | new `miner/group.lua`; hooks in `miner/mine.lua` (lane entry points) and `miner/miner.lua` (phases) |
| AR-3 | Monitor: group page (claims map, lane segments + direction, station queue), JOIN/LEAVE/RELEASE/PAUSE GROUP/RETURN GROUP; fits 26x20, keyboard-first | new `servers/tm_army_ui.lua`; 1 hook in `tm_views.lua` |
| AR-T | Simulator: many turtles in one world without collisions (a cell holds one turtle; moving into a turtle fails), frozen/unloaded turtle, scenarios below | `test/lib/army.lua`, `test/scenarios/80_*`.. `89_*` |
| AR-R | Review + your in-game test | |

Simulator scenarios to add: 4 and 20 turtles finish a grid with no collisions; a frozen turtle in the shaft (others wait, nothing reassigned); server restart mid-run; a solo turtle joins a running group; basic modems only (timed slots) and with a relay at the shaft bottom; full chest at the station; two solo turtles with overlapping grids get shifted apart; two solo turtles meeting head-on resolve right of way.

## Splitting it across sub-agents

Rules that keep agents cheap and conflict-free:
- **One agent owns each new file**; hooks into shared files are a few lines, listed in the table above, so merges are trivial.
- **Contracts first.** AR-0 is written by the coordinator (not an agent): message fields and function signatures in PROTOCOL.md / INTERFACES.md. Every later agent codes against it and does not change it; if it must, it stops and reports.
- **Sonnet for all build agents**, short briefs (goal, owned files, contract section, the scenarios it must make pass, report in under 15 lines). Opus only for the final review if wanted.
- Each agent starts from `origin/main`, commits in its worktree, does not push; the coordinator merges, runs the suite, opens one PR per batch.

| Batch | Agents (in parallel) | Needs | Size (rough) |
|-------|----------------------|-------|--------------|
| 0 | Coordinator writes AR-0 | — | small |
| 1 | **A: AR-1 coordinator** (`tm_army.lua`) · **B: AR-T sim + scenarios** (`test/lib/army.lua`, scenarios written against the contract, SKIP until modules exist) | AR-0 | A large, B medium |
| 2 | **C: AR-2 turtle group mode** (`group.lua` + hooks) · **D: AR-3 monitor group page** (`tm_army_ui.lua`) | A merged (C talks to it; D reads its records) | C large, D small |
| 3 | **E: solo safety** (overlap check at install/boot + right of way when two turtles meet) | C merged (shares the lane/turtle-detect code) | small |
| 4 | Coordinator: integration, full suite, PR; optional Opus review agent; your in-game test | all | — |

Batch 1 and 2 each run two agents side by side; nothing in a batch edits the same file. If a batch's agent finishes early, the next batch's independent agent can start (D only needs A's record format, so it can start as soon as A commits).

## Answers (2026-10-31)

1. **Second shaft:** yes. `GROUP_SHAFTS` = 1 or 2 (one down, one up). The monitor suggests 2 when the average shaft wait goes over a set limit.
2. **Server location:** usually near the mine, but must work at a distant base too. The "never reassign a silent turtle's claims or segments" rule covers both.
3. **GPS nodes:** hardware is ready. `gpsnode` still gets written for health reporting and easy setup, and can adopt an existing `gps host` computer (reads its startup coordinates).
4. **Joining without GPS:** carrying it to the station is fine.
