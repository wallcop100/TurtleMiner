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

| WP | What | Files |
|----|------|-------|
| AR-0 | Protocol additions (claim, lease, segment request/grant/release, group join/leave, gps node health) and interfaces | docs |
| AR-1 | Coordinator: groups, grid, claims, segment locks with direction | `servers/coord.lua`, hook into `central_monitor.lua` |
| AR-2 | Turtle group mode: get work from the coordinator, request segments before shared lanes, wait/queue behaviour, join/leave | `miner.lua`, `mine.lua`, `net.lua` |
| AR-3 | Bridge: turtle relay mode, `relay` program | `net.lua`, `servers/relay.lua` |
| AR-4 | GPS nodes: `gpsnode` program, health reporting, setup | `servers/gpsnode.lua`, `setup.lua` |
| AR-5 | Monitor group view and commands (fits 26x20) | `central_monitor.lua` |
| AR-T | Simulator: many turtles in one world, GPS range limit, relay chains, unloaded (frozen) turtles | `test/**` |
| AR-R | Review + your in-game test | |

Simulator scenarios to add: 4 and 20 turtles finish a grid with no collisions; a frozen turtle in the shaft (others wait, nothing reassigned); server restart mid-run; a solo turtle joins a running group; a relay chain of 3; GPS out of range falls back to the journal; full chest at the station.

## Answers (2026-10-31)

1. **Second shaft:** yes. `GROUP_SHAFTS` = 1 or 2 (one down, one up). The monitor suggests 2 when the average shaft wait goes over a set limit.
2. **Server location:** usually near the mine, but must work at a distant base too. The "never reassign a silent turtle's claims or segments" rule covers both.
3. **GPS nodes:** hardware is ready. `gpsnode` still gets written for health reporting and easy setup, and can adopt an existing `gps host` computer (reads its startup coordinates).
4. **Joining without GPS:** carrying it to the station is fine.
