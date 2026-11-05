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

## Decisions (approved 2026-11-05)
| Topic | Decision |
|-------|----------|
| Entry tunnel | One shared 1x1 shaft from the station; turtles take turns by direction in convoys. The coordinator digs a **second shaft** (down/up) automatically when queues get long |
| Army setup | **Wizard on the monitor**. Station given by **typed coordinates** (X Y Z + facing). Wizard asks **depth (TARGET_Y) and ore focus**; everything else defaults and is editable later |
| Area | **Ever-growing from an origin** (the station). No size setting: the coordinator keeps adding corridors outward, nearest-first |
| UI | **Top-down map**, **traffic view**, **army stats** (plus the existing list/alerts) |
| Mined knowledge | **Branch progress + reported extra digs** (veins, detours) — no per-block map |
| Avoid | Army turtles avoid **solo turtles** (their planned grids) and **turtles without modems** (treated as obstacles: wait, never dig) |

## How it works

### 1. Shared entry tunnel (station + shaft)
- Station = typed origin `(x,y,z,facing)`. The shaft column is one block **in front** of the station spot (keeps the chest-behind/beside rule; the station spot stays free for unloading).
- Shaft split into 16-block **segments**; a segment holds a direction (down/up) and any number of turtles going that way (convoy); flips only when empty.
- Out of contact (basic modems): the **up** trip uses a **timed slot** booked before leaving; with a relay at the shaft bottom or any ender modem, live reservations instead.
- Second shaft: coordinator measures average wait; above a threshold (default 60 s) it assigns the next free turtle a "dig up-shaft" job next to the first; once done, shaft 1 = down, shaft 2 = up, no direction flips.
- Station queue: one turtle at the station spot at a time (unload, refuel), others wait in the up-shaft below; full chest = one army alert, all wait.

### 2. Army setup (wizard)
- Monitor: `NET > ARMY > New`: name, station X Y Z, facing (N/E/S/W), TARGET_Y, FOCUS. Validates coordinates are integers and Y above TARGET_Y.
- Joining: place a turtle **at the station spot** and press JOIN on its card (or `install --army <name>`, or key `J` on the turtle). A turtle at the station adopts the station's **world coordinates** as its home, so turtles **without GPS** work in world coordinates too. GPS turtles elsewhere can walk there.
- Leaving: LEAVE → it finishes its branch, returns, unloads, drops back to solo at its old home (kept).
- Settings stored on the leader (replicated in the cluster DB); turtles get them with each claim, so changing them on the monitor applies at the next claim.

### 3. Ever-growing grid + shared knowledge
- Grid in the station frame: spine and corridors as today (`miner/mine.lua` layout), but corridors are created **on demand in both directions** (right and left of the spine, then further), nearest unclaimed branch first, so travel stays short.
- Coordinator keeps per branch: `free | claimed(turtle, since) | done(step)` plus a list of **extra digs** (cells off the grid: vein cells, detours) reported by turtles in their `catchup`/status when back in contact.
- A turtle mines only its claimed branch; before a vein step into a cell already in the extra-digs list it skips it (that ore is gone).
- **Never reassign a silent turtle's branch or segment** (it is probably frozen in place); `RELEASE` on the monitor frees it.
- Solo turtles: their planned grid (home + facing + geometry, already in status) is registered; the army's grid skips overlapping branches; a solo turtle installed overlapping an army is shifted/warned.
- Unknown turtle in the way (no modem, other network): wait, never dig/attack it; after timeout report `blocked by unknown turtle at x,y,z`.

### 4. UI / UX (new army page, keyboard-first, fits 26x20 up to big monitors)
- **Map**: top-down grid around the station; one character per cell group: `#` done, `+` claimed, `.` free, `S` station/shaft, turtle digits/letters for positions with direction arrow; scroll with arrows, zoom levels by screen size.
- **Traffic**: shaft segments with direction and occupants, station queue order, who waits for whom, slot schedule for out-of-range turtles.
- **Stats**: ores per hour (per ore family), branches done/claimed, % done of the current ring, fuel used, turtles active/away/help.
- **Actions**: JOIN/LEAVE (on a turtle card), RELEASE (on a claim), PAUSE ARMY, RETURN ARMY, army settings.
- Existing list/alerts stay; army turtles grouped under their army.

## Multi-level mining (army only, decided 2026-11-05)

- **Levels come from ore-height presets.** The wizard asks which ores to target (diamond, redstone, lapis, gold, iron, copper, coal, emerald, ancient debris). Each ore adds its 1.18 best height as a level, for example diamond -58, redstone -58, lapis 0, gold -16, iron 16, copper 48, coal 96. Duplicates are merged, and levels closer together than 4 blocks are merged into one. The list is shown in the wizard and can be edited later (add or remove a Y) from the army settings.
- **One shared shaft serves every level.** Each level has its own spine, corridors and branches from the shaft, in the same station frame. Shaft segments are reserved the same way at every depth.
- **All levels run in parallel.** The coordinator hands out the nearest free branch across all levels, weighted by trip length (deeper levels cost more), so turtles spread over the levels and the near work goes first.
- **Each level has its own ore focus:** a level made from the diamond preset vein-mines diamond and redstone first, but still takes any ore it passes.
- Solo turtles stay single-level (`TARGET_Y`).

## Mobile GPS: every turtle with a known position is a GPS host (decided 2026-11-05)

- **All turtles, solo or army, automatically. No prompt, no setup, no buttons:** you never have to interact with a turtle for this. Nobody parks. Every turtle with a modem answers GPS pings (`gps.CHANNEL_GPS`, "PING", like `gps host`) **with its current position, while it works**. It answers only between moves (never mid-move) and only when its position is certain:
  - its coordinates are world coordinates (it has had a GPS fix, or it joined an army at the typed station; a solo turtle without GPS works relative to its home and never hosts);
  - it isn't `lost`, isn't settling a crash, and has no pending journal intent.
- **Where it helps:** turtles spread across shafts, spines, corridors and levels give a turtle at depth 4 or more hosts in range that aren't all in one plane. Multi-level armies and shaft traffic make that likely. `gps.locate` itself rejects ambiguous layouts, so a bad set just means no fix that moment.
- **Safety:** a turtle uses a fix only if it agrees with its own journal within 2 blocks; otherwise it keeps its journal position and logs the disagreement. One wrong host can't move anyone.
- **Cost:** a reply is one small message per ping, and pings come only from turtles that need a fix (at boot, after a crash, when surfacing, after a failed locate once they've moved 16 blocks).
- **Live reporting is not needed for this.** A host's answer is only as good as its own position, and that is checked locally. The monitor's GPS page shows mobile hosts it has heard recently.
- **Off switch:** turtle setting `MOBILE_GPS` (default on), and the same as an army setting. The monitor's GPS page only *shows* mobile hosts heard recently (count, positions); there's nothing to configure.
- **Not army-only:** this is built into the turtle's comms loop, so it can ship before the army (its own small work package, AR-G).

## Work packages

Already done elsewhere (not army work any more): bridge/relay (COMMS CM-5), GPS hosting and offer (CLUSTER_GPS CG-3/4), mesh updates (MU). The army builds on them.

| WP | What | Files (owner) |
|----|------|---------------|
| AR-0 | Protocol + interfaces: `group_join/leave`, `claim_req/grant/done/release`, `seg_req/grant/release`, `slot` (timed shaft window), `station_q`; group record format; turtle-side `group` API | `docs/PROTOCOL.md`, `docs/INTERFACES.md` |
| AR-1 | Coordinator on the leader: group records, shared multi-level grid (levels from ore presets) (reuses mine.lua's layout maths), branch claims, segment locks with direction/convoys, timed up-shaft slots, station queue, replicated through the cluster DB, "never reassign a silent turtle" + RELEASE | new `servers/tm_army.lua`; 1 hook each in `tm_radio.lua` (message branch) and `tm_db.lua` (replicated table) |
| AR-2 | Turtle group mode: settings `GROUP`, ask for a claim at the station, mine only that branch, ask for segments before shared lanes (shaft/spine/mains), wait/queue, use slots when out of contact, join/leave, overlap check + right of way for solo turtles | new `miner/group.lua`; hooks in `miner/mine.lua` (lane entry points) and `miner/miner.lua` (phases) |
| AR-3 | Monitor: group page (claims map, lane segments + direction, station queue), JOIN/LEAVE/RELEASE/PAUSE GROUP/RETURN GROUP; fits 26x20, keyboard-first | new `servers/tm_army_ui.lua`; 1 hook in `tm_views.lua` |
| AR-T | Simulator: many turtles in one world without collisions (a cell holds one turtle; moving into a turtle fails), frozen/unloaded turtle, scenarios below | `test/lib/army.lua`, `test/scenarios/80_*`.. `89_*` |
| AR-G | Mobile GPS host on every turtle (reply loop, certainty checks, journal cross-check of fixes, GPS-page list) | `miner/net.lua` hook + new `miner/gpsmobile.lua`; small `tm_gps.lua` view hook |
| AR-R | Review + your in-game test | |

Simulator scenarios to add: 4 and 20 turtles finish a grid with no collisions; a frozen turtle in the shaft (others wait, nothing reassigned); server restart mid-run; a solo turtle joins a running group; basic modems only (timed slots) and with a relay at the shaft bottom; full chest at the station; two solo turtles with overlapping grids get shifted apart; two solo turtles meeting head-on resolve right of way.

## Contracts (batch 0) — every army agent codes against this

### Frame and keys
- **Station frame:** origin `S = {x, y, z}` (world, typed in the wizard) and facing `sf` (0 N, 1 E, 2 S, 3 W). `F` = unit vector of `sf`, `R` = `sf + 1`. A cell is written `(f, r, y)` in that frame; `toWorld(f, r, y) = S + f*F + r*R` with `y` taken as world Y. This is the same maths as `mine.toWorld` with `home = S`, `homeFacing = sf`.
- **Station spot:** `(0, 0, S.y)`. Chests sit behind or beside it.
- **Shafts:** shaft `k` (1 or 2) is the column at `f = 1, r = k - 1`, running from `S.y - 1` down to the deepest level. Shaft 1 is used both ways until shaft 2 exists; after that, shaft 1 is **down** and shaft 2 is **up**.
- **Geometry `geom = {bl, sp, ml}`** (`BRANCH_LENGTH`, `BRANCH_SPACING`, `MAIN_LENGTH`) is fixed per army.
  - `W = 2*bl + sp`.
  - **Level** `y` (world Y, from the ore presets).
  - **Spine** of level `y`: `f = 2`, along `R`, both directions (`r` from `-∞` to `+∞`).
  - **Corridor** `c` (any integer, negative = left of the shaft): main at `r = c*W`, `f = 2 .. 1 + ml`.
  - **Branch** `b >= 0`, side `"L"|"R"`: at `f = 2 + (b+1)*sp`, length `bl`.
- **Branch key:** `"y:c:b:side"`, e.g. `"-58:-1:3:R"`. **Segment key:** `"s<k>:<i>"` for shaft `k`, 16-block segment `i` (0 = top); `"sp<y>:<j>"` for spine segment `j` of level `y` (`j` = floor(r/16), signed); `"m<y>:<c>:<i>"` for corridor mains.

### Army record (leader, replicated in the cluster DB as `S.armies[name]`)
```
{ name, station = {x,y,z,f}, levels = { {y=-58, focus={"diamond","redstone"}}, ... },
  geom = {bl,sp,ml}, settings = {FUEL_MARGIN, DROP_TRASH, ...},
  shafts = { {k=1, done=true}, {k=2, done=false, digger=id|nil} },
  members = { [turtleId] = {joined=ms, state="work"|"away"|"leaving"} },
  branches = { [key] = {state="free"|"claimed"|"done", tid=id, since=ms, step=n} },
  extra = { ["x,y,z"] = ms, ... },          -- off-grid cells dug (veins, detours), world coords
  segs = { [segKey] = {dir="down"|"up"|"in"|"out", holders={[tid]=ms}} },
  slots = { {tid, shaft=k, dir, at=ms, len=ms} },   -- timed shaft windows for turtles out of contact
  queue = { tid, ... },                      -- station queue order
  stats = { ores={[family]=n}, branchesDone=n, startedAt=ms, fuelUsed=n },
  paused = bool, wait = { avgMs, n } }       -- shaft wait average (second-shaft trigger) }
```

### Messages (signed TMINER kinds; `to = "server"` = the leader)
| kind | from → to | body |
|------|-----------|------|
| `army_new` | UI → leader | `name, station, ores={...}` (ore preset ids), `targetY?` (override) |
| `army_set` | UI → leader | `name, key, value` (settings, levels add/remove, `paused`) |
| `army_join` | turtle → leader | `name, at={x,y,z,f}` (its position; must equal the station spot) |
| `army_leave` | turtle → leader | `name` |
| `army_cfg` | leader → turtle | the record minus `branches/extra/segs/slots` (what a member needs) |
| `claim_req` | turtle → leader | `name, pos, fuel` |
| `claim` | leader → turtle | `key, level={y,focus}, geom, step, near={ "x,y,z", ... }` (extra digs within 3 blocks of the branch) or `wait=sec` / `dig_shaft=k` |
| `claim_done` | turtle → leader | `key, step, ores={[family]=n}, extra={"x,y,z",...}, fuelUsed` |
| `seg_req` | turtle → leader | `segs={key,...}, dir` |
| `seg_grant` | leader → turtle | `segs={key,...}` granted, or `wait=sec` |
| `seg_release` | turtle → leader | `segs={key,...}` |
| `slot_req` | turtle → leader (before leaving) | `shaft, dir="up", eta=ms` |
| `slot` | leader → turtle | `shaft, at=ms, len=ms` |
| `station_q` | leader → turtle | `pos` (place in queue), `go=bool` |
| `army_release` | UI → leader | `name, tid` (free a silent turtle's claim and segments) |

Rules: the leader never reassigns anything held by a silent turtle (only `army_release` does). A turtle out of contact uses its booked `slot`; with contact it uses `seg_req`. Extra digs also arrive in `catchup`.

### Turtle side (`miner/group.lua`)
```
group.init(st, cfg, nav, inv, mine, net, ctl)
group.active() -> bool                         -- member of an army
group.join(name) -> ok, reason                 -- only at the station spot; adopts station frame as home
group.leave()
group.nextJob() -> job | nil, waitSec          -- asks claim_req (or uses a cached claim when out of contact)
group.enterLane(segs, dir) -> true | false, reason   -- blocks (calling ctl.check) until granted or slot time
group.leaveLane(segs)
group.reportDig(pos)                           -- off-grid cell dug
group.jobDone(job, result)
```
`mine.lua` gets one hook: `opts.lane(segs, dir)` called before entering a shaft/spine/main segment and `opts.unlane(segs)` after leaving, plus `mine.runBranch(job)` that mines one claimed branch in the station frame. Without an army, the hooks are no-ops and solo mining is unchanged.

### Ore presets (`levels` from the wizard)
`diamond -58, redstone -58, lapis 0, gold -16, iron 16, copper 48, coal 96, emerald 232, ancient_debris (Nether) 15`. Levels closer than 4 blocks merge; each level's `focus` lists the ores that produced it.

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
