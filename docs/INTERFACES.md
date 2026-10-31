# Module Interfaces (contract)

Every agent codes against this file. If something here is wrong or missing, stop and report it; don't change another module's API on your own.

## General rules

- Target: CC:Tweaked (Cobalt, Lua 5.2 semantics). No `//`, no bitwise ops, no `goto`, no `<const>`. `math.floor` all coordinates.
- Turtle files live flat in the turtle root. Load with `require("name")`. Each module returns a table; no globals (other than CC's own: `turtle, fs, os, rednet, gps, peripheral, settings, textutils, sleep, parallel, term, colors, keys, pocket`).
- First line of every file: `-- Version: x.y.z`. New files start at `1.0.0`.
- No `read()` outside `install.lua`. No `error()` for expected failures; return `false, reason`.
- Keep files under ~600 lines.

## Shared types

```
Pos    = {x=int, y=int, z=int}
Facing = 0 north (-z) | 1 east (+x) | 2 south (+z) | 3 west (-x)
         In relative mode (no GPS) 0 means "the direction the turtle faced at setup".
Job    = {corridor=int>=0, branch=int>=0, side="L"|"R", step=int>=0}
Phase  = "BOOT" | "RECOVER" | "TO_WORK" | "MINING" | "VEIN" | "RETURNING"
       | "UNLOADING" | "REFUELING" | "IDLE" | "PAUSED" | "NEEDS_HELP" | "ERROR" | "DONE"
```

## State table (`st`), owned by state.lua, mutated by nav/mine/miner

```
st = {
  schema   = 1,
  pos      = Pos, facing = Facing,
  home     = Pos, homeFacing = Facing,
  gps      = bool,          -- true: world coords; false: relative frame, GPS never used
  phase    = Phase, reason = string|nil,
  job      = Job,
  flags    = {resetJob=bool, update=bool},
  stats    = {ores=0, blocks=0, trips=0, started=epoch},
  lastError= string|nil,
}
```

## config.lua (WP-C)

```
config.DEFAULTS            -- table of every key with default value (see file)
config.REMOTE_KEYS         -- set of keys changeable by SET command
config.load() -> cfg       -- DEFAULTS merged with settings.get("tminer."..key)
config.set(key, value) -> ok, err   -- validates type/range, settings.set + settings.save
```

## state.lua (WP-A)

Two files: snapshot `.tm_state` (atomic: write `.tm_state.tmp`, delete old, move) and append-only journal `.tm_journal`.

```
state.new(home, homeFacing, gps) -> st
state.load() -> st|nil            -- tries .tm_state, then .tm_state.tmp; nil if neither parses
state.save(st) -> ok              -- atomic snapshot; also truncates the journal and writes a "S" line
state.wipe()                      -- delete all state files (not settings)

-- Journal (one line per record, space separated, numbers only after the tag):
state.logIntent(op, fuel)         -- "I <op> <fuel>" before a move/turn. op: f b u d l r
state.logDone(st, fuel)           -- "D <x> <y> <z> <facing> <fuel>" after success
state.logRefuel(fuel)             -- "R <fuel>" after any refuel
state.readJournal() -> {entries}  -- each {tag="I"|"D"|"R"|"S", op=, x=,y=,z=,facing=, fuel=}
```
- `state.save` is called on every phase change and every `SNAPSHOT_EVERY` (config, default 100) moves; the journal is the per-move record.
- Journal is opened with mode `"a"`, written and closed per record (CC flushes on close).
- If the journal grows past 2000 lines without a save, `logDone` triggers `state.save` itself.

## nav.lua (WP-A)

```
nav.init(st, opts)
  opts.shouldAbort() -> bool         -- polled inside retry loops; true = return false,"abort"
  opts.onMove(st)                    -- called after every successful move (main uses for throttled status)
  opts.save()                        -- calls state.save(st)
nav.forward(dig) / nav.up(dig) / nav.down(dig) -> ok, reason
  dig default true. Retries dig+attack. Gravel/sand/mobs: keep trying.
  Gives up with reason: "unbreakable" | "no_fuel" | "timeout" (60 s no progress) | "abort" | "blocked" (dig=false)
nav.back() -> ok, reason             -- no dig; falls back to turnAround+forward+turnAround if blocked
nav.turnLeft() / nav.turnRight() / nav.face(dir)
nav.goTo(target, opts) -> ok, reason
  opts.order: optional string of axis letters, e.g. "xzy", "yxz".
  Default order: if moving up to target, horizontal first then up; if going down, down first then horizontal.
  On failure, tries one alternative order before returning false.
nav.dist(a, b) -> manhattan int
nav.fuelToHome(st) -> int            -- dist(pos, home)
nav.recover(st) -> ok, reason        -- see below; called once at boot before anything moves
nav.gpsLocate() -> Pos|nil           -- gps.locate(2), floored; nil if no GPS or st.gps false
nav.calibrateFacing() -> ok, reason  -- GPS only: move one block (forward, else back, else up+forward), compare
```

Every move/turn: `state.logIntent(op, fuelBefore)` → `turtle.x()` → on success update `st.pos/facing`, `state.logDone(st, fuelAfter)`, `opts.onMove(st)`.

### nav.recover(st) algorithm

1. Read journal. Start from snapshot `st` and replay `D` lines to get the "file" state, plus the list of `D` entries (pos, facing, fuel) since the snapshot.
2. If the last line is `I` with no matching `D`: the op may or may not have happened.
   - Move op, numeric fuel: if `turtle.getFuelLevel() == intentFuel - 1` it happened, apply it; if equal to `intentFuel`, it didn't.
   - Turn op: undecidable from fuel. If GPS mode, step 4 fixes it. Else set `NEEDS_HELP` with reason `"facing unknown after crash"` unless the turn was the second half of a `turnAround` pattern the journal can disambiguate. (Keep it simple: report it.)
3. **World rollback check** (numeric fuel only): if the world's fuel is higher than the fuel of the last `D`, the world rolled back. Walk `D` entries backwards (and the snapshot) to the most recent one whose fuel equals world fuel, adjusting for `R` lines (a refuel between that point and now means the world also lost that refuel). Use that entry's pos/facing. If none matches: GPS → step 4; else `NEEDS_HELP` "position unknown after crash".
4. If `st.gps`: `gpsLocate()` overrides pos. If it differs from the replayed pos, emit an event. If facing is in doubt (step 2/3), `calibrateFacing()`.
5. `state.save(st)`; return `true` or `false, reason`.

## inv.lua (WP-B)

```
inv.init(st, cfg, nav)
inv.slotsFree() -> int
inv.isFull() -> bool                    -- slotsFree() < 2
inv.dropTrash() -> int                  -- drops cfg.TRASH items (dropDown in the tunnel), returns slots freed
inv.refuel(target) -> fuelAfter         -- burn fuel items from inventory until fuel >= target or none left;
                                        -- keeps cfg.FUEL_KEEP items of fuel in reserve; calls state.logRefuel
inv.fuelNeeded(st) -> int               -- nav.fuelToHome(st) + cfg.FUEL_MARGIN
inv.fuelOk(st) -> bool                  -- fuel == "unlimited" or fuel >= fuelNeeded
inv.scanHome() -> {dump=side|nil, fuel=side|nil, sides={...}}
  -- at home: checks top/bottom/front/back/left/right for inventories (peripheral.getType / hasType "inventory",
  --   fallback: inspect name contains chest/barrel/shulker). An inventory whose list() is >50% fuel items is the
  --   fuel source; the first other one is the dump. One chest only -> dump only. Restores facing afterwards.
inv.unload() -> ok, reason              -- at home: dump all except fuel reserve. Reasons: "no_storage", "storage_full"
inv.restockFuel(target) -> fuelAfter    -- at home: suck from fuel inventory (if any) and burn up to target
```

## mine.lua (WP-B)

Home frame: `F` = homeFacing unit vector, `R` = homeFacing+1 unit vector. `toWorld(f, r, y)` maps frame coords to world coords.

Grid (all at `y = cfg.TARGET_Y`):
- Shaft: home x/z, from home y down to targetY. Fully dug once, then reused.
- Spine: along `R` at `f = 1`, from the shaft outward. Corridor `c` main tunnel starts at `r = c * W` where `W = 2*BRANCH_LENGTH + BRANCH_SPACING`.
- Main of corridor `c`: along `F`, `f = 1 .. MAIN_LENGTH`.
- Branch `b` of corridor `c`: at `f = 1 + (b+1)*BRANCH_SPACING`, both sides `L` (−R) and `R` (+R), `BRANCH_LENGTH` long.
- `job.step` = blocks completed along the current branch. Resume = `goTo(branch start)` then walk `step` blocks (already open) and continue.
- Stops with `DONE` after `MAX_CORRIDORS` corridors.

```
mine.init(st, cfg, nav, inv, ctl)
  ctl.check() -> nil | "return" | "stop"   -- called between every step; may block while PAUSED
mine.toWorld(f, r, y) -> Pos
mine.jobStart(job) -> Pos, facing          -- where a branch begins
mine.run() -> result, reason
  result: "full" (inventory) | "fuel" | "return" (command) | "stop" | "done" | "stuck"
  Handles: shaft descent, spine, mains, branches, ore checks on every step (inspect up, down, left, right, front),
  vein mining, trash dropping when nearly full. Advances st.job as it goes. Never goes home itself.
mine.isOre(blockData) -> bool, family     -- family strips "deepslate_" so both variants count as one vein
mine.vein(family) -> count                -- iterative DFS with an explicit stack, backtracks along its own path,
                                          -- cap cfg.VEIN_MAX blocks, honours ctl.check()
```

## net.lua (WP-C)

```
net.init(cfg) -> ok, err          -- opens every modem (wireless/ender first). ok=false means offline; everything else still works (no-op sends)
net.online() -> bool
net.send(kind, to, body)          -- fills envelope (PROTOCOL.md), never errors
net.event(level, text)
net.run(getStatus)                -- coroutine body, never returns:
                                  --   receives TMINER, dedupes, queues cmds addressed to us, sends ack,
                                  --   sends status every cfg.STATUS_INTERVAL using getStatus()
net.statusNow()                   -- ask run loop to send status at next tick (phase changes)
net.poll() -> cmd|nil             -- pop next queued cmd {id, cmd, params}
net.request(kind, body, replyKind, timeout) -> msg|nil   -- for home_get / update; safe to call from worker coroutine
```

## miner.lua (WP-C)

- `parallel.waitForAny(worker, function() net.run(getStatus) end)`.
- Worker = only coroutine that moves the turtle. State machine over `st.phase`. Whole worker in `xpcall(..., debug.traceback)`; on error: `st.lastError`, `phase = "ERROR"`, save, status, try `goTo(home)` once, then `NEEDS_HELP`, then wait for `RESUME` (loop, sleeping, still serving `ctl.check`).
- `ctl.check()` drains `net.poll()`, applies commands (PROTOCOL.md table), returns `"return"`/`"stop"`/nil; while `PAUSED` it blocks in a sleep loop.
- First boot (no state): if GPS → home = gps pos, calibrate facing, `st.gps = true`. Else ask server `home_get`; if found and gps=false then... cannot trust (turtle may not be at home) → `NEEDS_HELP` "state lost: place at home and send RESET_HOME". If nothing on server and no state: home = `{0,0,0}`, facing 0, `gps=false` (normal fresh install, turtle is at home by definition).
- `NEEDS_HELP` retry: chest full / no storage re-checked every 30 s automatically.

## installer / updater (WP-E)

- `install.lua`: the only interactive program. Writes `tminer.*` settings and `startup.lua`.
- `updater.lua`: `updater.run(opts) -> updated(bool)`; CLI `updater [--check]`. Called from `startup.lua` before `miner` when the state file says the turtle is at home (or no state). Never rewrites `startup.lua` if present.
- `startup.lua`: `shell.run("updater")` (guarded with pcall), then `shell.run("miner")`.

## Simulator (WP-T)

`test/sim/` provides fakes for all CC globals listed above and a voxel world. API for tests:

```
local sim = require("sim")
local w = sim.world()                       -- empty stone world, bedrock at y <= -60
w:set(x,y,z,name) / w:get(x,y,z)
w:chest(x,y,z, {items}) / w:chestContents(x,y,z)
local t = sim.turtle(w, {id=1, pos=, facing=, fuel=, fuelLimit=20000, gps=bool, inventory={...}})
sim.boot(t, {"miner"}, {maxTicks=N, crashAt=fn(event)->bool})  -- runs the program from a fresh Lua env with
                                            -- the turtle's own fs (a table). crashAt lets a test kill it at a
                                            -- given op or mid-file-write.
sim.rollback(t, snapshot)                   -- world+turtle back to an earlier snapshot, fs untouched (server crash)
sim.net                                     -- in-memory rednet shared by all sim computers
```
Time is simulated (sleep advances a clock instantly). `os.epoch("utc")` follows the sim clock.
