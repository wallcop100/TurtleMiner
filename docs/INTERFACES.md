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
  stats    = {ores=0, blocks=0, trips=0, started=epoch,
              moveSec, tripSec, lastTripSec,       -- measured: s per fuel unit, full-trip lengths (s)
              tripStart, tripFuel0, tripNatural},  -- current trip (cleared on arrival home)
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
state.save(st, fresh) -> ok       -- atomic snapshot; also truncates the journal and writes a "S" line
                                  -- (keeps the last 1000 D/R/S lines as history; fresh=true keeps none:
                                  --  used after a world rollback and on RESET_HOME)
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
  opts.isKnownOpen(pos) -> bool      -- optional: cells known dug (main passes mine.isKnownOpen)
  opts.knownBlock(pos) -> name|nil   -- optional: stable blocks known there (main: home storage, st.homeMarks)
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
nav.gpsLocate(force) -> Pos|nil      -- gps.locate(2), rounded; nil if no GPS or st.gps false. After a failed
                                     -- locate it returns nil at once until the turtle climbed 16 blocks or is
                                     -- within 16 of home (force = try anyway). GPS = "available here now".
nav.calibrateFacing() -> ok, reason  -- GPS only: move one block (forward, else back, else up+forward), compare
```

Every move/turn: `state.logIntent(op, fuelBefore)` → `turtle.x()` → on success update `st.pos/facing`, `state.logDone(st, fuelAfter)`, `opts.onMove(st)`.

### nav.recover(st) algorithm

1. Read journal. Start from snapshot `st` and replay `D` lines to get the "file" state, plus the list of `D` entries (pos, facing, fuel) since the snapshot.
2. If the last line is `I` with no matching `D`: the op may or may not have happened.
   - Move op, numeric fuel: if `turtle.getFuelLevel() == intentFuel - 1` it happened, apply it; if equal to `intentFuel`, it didn't.
   - Turn op: undecidable from fuel. The block name stored in the intent settles it when the front changed (stable solid involved). Otherwise the facing has 2 candidates (offsets in `st.facingCands`).
   - Unlimited fuel move: intent block name, else the known-open map (front/up/down) when it tells the 2 candidate positions apart.
3. **World rollback check** (numeric fuel only): if the world's fuel is higher than the fuel of the last `D`, the world rolled back. Walk `D` entries backwards (and the snapshot) to the most recent one whose fuel equals world fuel, adjusting for `R` lines (a refuel between that point and now means the world also lost that refuel). Use that entry's pos/facing. If none matches: GPS → step 4; else `NEEDS_HELP` "position unknown after crash".
   A rollback marks `st.job.noGrid` and the final save is fresh (journal lines past the rollback point are no evidence).
4. If `st.gps` and `gpsLocate()` gives a fix: it overrides pos (event if it differs); facing in doubt → `calibrateFacing()` (if that fails without a GPS correction: blind probe).
   No fix (no GPS mode, or out of range underground): blind recovery. Facing in doubt → probe: 3 journaled right turns, inspect the 4 neighbours, keep the candidate facings under which no known-open cell (journal positions up to a rollback point + `opts.isKnownOpen`) shows a stable solid block and no `opts.knownBlock` cell shows a different stable block; exactly one = settled. Ambiguous in the home column below home: climb the open shaft to home and probe there. Else `NEEDS_HELP` "facing unknown after crash (probe: n facings fit)". A crash mid-probe restarts it (`st.facingUnknown` + `st.facingCands` are saved first).
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
mine.isKnownOpen(pos) -> bool              -- grid cell the saved job has completed (job.geom.y == TARGET_Y, no
                                           -- job.noGrid); conservative, false = unknown. Used by nav.recover.
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
net.modemKind() -> "none"|"basic"|"ender"|"wired"   -- detected (equipped upgrade name / peripheral name
                                  -- contains "advanced", or a basic sender heard > 400 blocks away); tminer.MODEM overrides
net.hop() -> n|nil, via           -- distance to the server: 1 + min hop heard in the last 30 s
net.inContact() -> bool           -- hop known (or first 30 s after boot, nothing heard yet)
net.pendingEvents() -> n, dropped -- catch-up buffer size
net.stats = {relayed, cancelled, bad, lastBad}   -- bad = foreign/unsigned/tampered/stale messages dropped
net.network() -> name|nil         -- mining network (.tm_network); nil = none: online() is false, nothing sent or accepted
```
- Signing (PROTOCOL.md "Signing"): `net.send` signs every message; received messages are deduped first, then checked (tag, window, HMAC); failures are dropped, never relayed.
- Out of contact: `status` sends skipped (sent when contact returns), `net.event` buffers (coalesced, max 50) and one `catchup` goes out on contact. Relays per PROTOCOL.md (`tminer.RELAY`).
- miner: before leaving home (`TO_WORK` from home) sends `away` with the trip estimate; measures each trip into `st.stats`.

## miner.lua (WP-C)

- `parallel.waitForAny(worker, function() net.run(getStatus) end)`.
- Worker = only coroutine that moves the turtle. State machine over `st.phase`. Whole worker in `xpcall(..., debug.traceback)`; on error: `st.lastError`, `phase = "ERROR"`, save, status, try `goTo(home)` once, then `NEEDS_HELP`, then wait for `RESUME` (loop, sleeping, still serving `ctl.check`).
- `ctl.check()` drains `net.poll()`, applies commands (PROTOCOL.md table), returns `"return"`/`"stop"`/nil; while `PAUSED` it blocks in a sleep loop.
- First boot (no state): if GPS → home = gps pos, calibrate facing, `st.gps = true`. Else ask server `home_get`; if found and gps=false then... cannot trust (turtle may not be at home) → `NEEDS_HELP` "state lost: place at home and send RESET_HOME". If nothing on server and no state: home = `{0,0,0}`, facing 0, `gps=false` (normal fresh install, turtle is at home by definition).
- `NEEDS_HELP` retry: chest full / no storage re-checked every `HELP_RETRY` s automatically. "stuck" (timeout, mobs; not "unbreakable") goes back to work after `HELP_RETRY*4` s, at most 5 times (`st.flags.stuckRetries`, reset by progress or `RESUME`), then stays.
- First boot with GPS and a server home record: adopt it only when the GPS position is in its column or within 3 blocks on every axis; otherwise `NEEDS_HELP` "state lost: send RESET_HOME here or carry to home" (retries the distance check, so carrying it home works).
- After a reboot: `PAUSED` stays `PAUSED` where it is; `IDLE`/`DONE` stay if at home; work phases resume.
- `DONE` + `RESUME`: continues when `job.corridor < MAX_CORRIDORS` (after `SET MAX_CORRIDORS`) or after `RESET_JOB`.
- `UPDATE`: runs at the next home visit (REFUELING) or at once if `IDLE`/`DONE` at home; afterwards (or after the update reboot) the turtle continues with the phase it would have taken.
- `SET HOME_Y` without GPS: refused (nack) unless at home; applied by shifting the frame, wiping the journal and saving a fresh snapshot.
- `VERSION` is read from the first line of `miner.lua` at runtime.
- Screen: top 5 lines of the terminal are a status block (phase+label, reason, pos/fuel, job/ores, key line), redrawn on phase change and every 10 s; `print` is redirected into a window below it. Skipped on screens smaller than 20x8 or without the window API.
- `SURFACE_IF_LOST` (default false): after `nav.recover` fails at boot (not from home, its column or above home - 3), dig straight up via `nav.up` until 8 open cells in a row, a failed move (unbreakable/protected), fuel < 50, or 400 blocks; then `NEEDS_HELP` "lost: surfaced here, carry me home and press H twice" (`st.flags.surfaced`; `st.flags.surfacing` resumes the climb after a reboot). GPS-frame turtles try `gpsLocate` every 16 blocks and at the top; on a fix: calibrate, `RETURNING` with goTo order "xzy".
- `st.homeMarks` = {[world facing] = storage block name} recorded after the home scan in UNLOADING (fed to nav as `knownBlock`). RESET_HOME clears it, `st.facingCands` and the surfacing flags, and saves fresh.
- net: no modem (`net.online()` false) → `net.send` and the status timer do no work at all.

## installer / updater (WP-E)

- `install.lua`: the only interactive program. Writes `tminer.*` settings and `startup.lua`.
- `updater.lua`: `updater.run(opts) -> updated(bool)`; CLI `updater [--check]`. Called from `startup.lua` before `miner` when the state file says the turtle is at home (or no state). Never rewrites `startup.lua` if present.
- `startup.lua`: `require("updater").run(opts)` (guarded with pcall, only when at home: last D/S journal line is home, R lines ignored, trailing I line = not home; one reboot max via `.tm_updated`), then `shell.run("miner")`.
- `install.lua`: if old state files exist, asks whether this is a new home spot (deletes them); with no local state left it sends `home_clear` so the servers forget the old home.
- `install.lua` first joins the mining network (required; `tmjoin.ensure`); flags `--join <4 words> [--name n]`, `--create [name]`, `--disk [--wipe-disk]`, `--approve`, `--network` (change only). `updater` refuses replies not signed with the turtle's network.

## Mining network modules (MU-0)

```
tmcrypto: sha256(s), sha256hex(s), hmacFn(key) -> fn(msg) (pads precomputed), hmac/hmacHex(key, msg),
          canon(msg), signer(net) -> {tag, sign(msg), check(msg, nowMs) -> ok, why}, netTag(key),
          deriveKey(name, words, yield), normName(s), loadNetwork(path), saveNetwork(net, path),
          serializeNetwork(net), setBits("bit32"|"native"|"arith"), BITS, blocks (counter)
tmwords:  LIST (1024), INDEX, parse(text) -> words | nil, err, word, suggestion, suggest(w), random(n)
tmjoin:   ensure(opts) -> net, how ("existing"|"created"|"joined"|"disk"|"approved") | nil, err;
          parseArgs(args), create(name), fromText(text, name), make(name, words), phrase(net),
          findDisk(), toDisk(net), fromDisk(), wipeDisk(), requestApproval(opts)
```
- `.tm_network` = `{name, words, key}`; disk copy `<mount>/tm_network`. Servers (`tm_radio`): `T.loadNetwork()`, `S.network`, `S.signer`, `S.bad`, `S.badLast`, `T.joinList()`, `T.approveJoin(id)`, `T.dismissJoin(id)`, `T.netToDisk()`; UI views `net`, `netconfirm`, `netcode`.

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
sim.computer({pos=, modemKind="basic"|"ender"|"wired", wiredNet=, modems={{side,kind,net}}})
                                            -- no pos = in range of everyone (legacy default: ender)
turtle equip "computercraft:wireless_modem_normal" = basic, "..._advanced" = ender (default)
sim.modemRange(y), sim.reach(a, b)          -- 64 below Y 96 .. 384 at 320; max(sender, receiver); ender always; wired per net
sim.gpsHosts = {{pos=, kind=}}              -- optional: fixes need 3 hosts in reach (same rule)
sim.net.modemEvents = true                  -- also queue modem_message with the distance
sim.every(interval, fn)                     -- host-side ticker (fake servers' fleet heartbeat)
sim.computer/sim.turtle opts.network        -- .tm_network written at creation: default sim.defaultNetwork
                                            -- (harness: H.NET, words "lava oak ember pick", name "sim"); false = none
sim.drivePeripheral(c, side, mount)         -- disk drive with a floppy mounted at `mount` in c's fs
c.inputs = {"line", ...}                    -- scripted answers for read(); c.http = fn(url) -> body enables http.get
H.sign(msg, net), H.signer(net), H.network(name, words), H.installShared(c)   -- harness helpers
```
Time is simulated (sleep advances a clock instantly). `os.epoch("utc")` follows the sim clock.
