# TurtleMiner

A branch-mining program for CC:Tweaked turtles, with a central monitor (touchscreen or pocket computer) and an update server. The turtle saves its position before every move, so it survives server restarts and chunk unloads, reports what it is doing, and tells you plainly when it needs help. It never stops to ask questions after setup.

Parts:

| Part | Files | Runs on |
|------|-------|---------|
| Miner | `miner/*.lua` | each mining turtle |
| Monitor | `servers/central_monitor.lua`, `servers/startup.lua` | a computer with a monitor, or a pocket computer |
| Update server | `servers/update_server/*.lua` | any computer with a modem (can be the monitor computer) |

`farmer/` is a separate, older program and is not covered here.

## Hardware

- **Turtle** (advanced is nicer, not required) with a **pickaxe** equipped and a **wireless or ender modem** on the other side. Without a modem it still mines, but nothing can see or command it.
- **At home**: a chest **behind or beside** the turtle (not below: the shaft goes straight down from the home spot) for loot. Optional second chest with coal/charcoal as a **fuel chest** (detected automatically: an inventory that is mostly fuel). Works without a fuel chest, or with unlimited fuel.
- **Not on the modem side**: the turtle can't see a chest on the side where its modem is equipped (the modem takes that side). Put chests behind, on top, or on the pickaxe side.
- **Optional GPS** (4 GPS hosts). With GPS the turtle uses world coordinates and re-checks its position; without GPS it counts moves from home. Each turtle decides at boot. On its first start a GPS turtle works out which way it faces by stepping one block and back: leave a free block **in front of or behind** the home spot, or **above** it (with a free block in front of that one).
- **Server computer** with a wireless/ender modem. If turtles are far away, use ender modems, or several modems on the server (it relays `TMINER` messages between them).

### Space and chunks

- The grid is big. From the home spot the shaft goes down to `TARGET_Y`, then the spine runs to the **right** of the home facing for `MAX_CORRIDORS * (2*BRANCH_LENGTH + BRANCH_SPACING)` blocks (536 with the defaults), and each corridor's main tunnel runs `MAIN_LENGTH` (64) forward. Branches reach `BRANCH_LENGTH` (32) to each side of a main.
- Keep the home and the mining area **chunk-loaded** (chunk loader, or a player nearby) if you can. With the defaults that is far more than the chunks around one player. If a chunk unloads, the turtle stops and resumes where it was when the chunk loads again; lower `MAX_CORRIDORS`/`BRANCH_LENGTH` to keep the area small.
- **Several turtles**: their grids must not overlap. Space the homes further apart than the grid size above, or face them in different directions (the grid goes forward and to the right of each home).
- The turtle **attacks anything standing in its way** (mobs, and players too). Don't stand in its tunnels. Something that never moves makes it give up after `STUCK_TIMEOUT` and retry later (see `NEEDS_HELP`).

## Install

### Quick setup (HTTP API enabled in CC)

One command per computer. `setup.lua` downloads everything from the `claude/vigilant-pasteur-g2krss` branch (change `BRANCH` at its top once this is merged to `main`).

```
wget run https://raw.githubusercontent.com/wallcop100/TurtleMiner/claude/vigilant-pasteur-g2krss/setup.lua server
```

Use `server` on the main computer (monitor + update server, files in `/files/`), `monitor` for extra monitor computers, `pocket` on a pocket computer, `relay` on a plain computer that only extends the network (see "Comms"). Reboot each one afterwards. Then on each turtle at its home spot:

```
wget https://raw.githubusercontent.com/wallcop100/TurtleMiner/claude/vigilant-pasteur-g2krss/miner/install.lua install.lua
install
```

The installer pulls the miner files from the update server. With no update server, run `setup turtle` on the turtle first, then `install`.

### Manual setup

The examples use `wget` from GitHub; copying from a floppy disk works the same way. CC has no shell variables: wherever you see `BASE`, type `https://raw.githubusercontent.com/wallcop100/TurtleMiner/claude/vigilant-pasteur-g2krss` (or `.../main` once merged).

### 1. Update server (do this first)

On the server computer:

```
wget BASE/servers/update_server/update_server.lua update_server.lua
wget BASE/servers/update_server/startup.lua startup.lua
mkdir /files
```

Copy every file from `miner/` into `/files/` (`config.lua`, `state.lua`, `nav.lua`, `inv.lua`, `mine.lua`, `net.lua`, `miner.lua`, `updater.lua`, `install.lua`, `startup.lua`), e.g. `wget BASE/miner/nav.lua /files/nav.lua`. Then `reboot`.

**Auto-pull from GitHub:** the update server checks GitHub at boot and then every 60 minutes, and copies in any file whose `-- Version:` line is newer (only if it compiles). It also updates its own programs (`central_monitor.lua`, `update_server.lua`) and reboots once when they change. Settings on the server: `set tminer.pull_minutes 0` = boot only, `set tminer.auto_pull false` = off, `set tminer.repo_base <raw URL ending in />` to pull from another branch (e.g. `main` after merging). Needs the HTTP API.

The server reads the version from each file's first line (`-- Version: x.y.z`) and serves the files to turtles that ask. To roll out a change, bump the version line and drop the file in `/files/`: no restart needed. Turtles pick it up the next time they boot at home, or when you send `UPDATE`. A folder `/files/miner/`, if present, is used instead of `/files/` for miners.

If the monitor runs on the same computer, its `startup.lua` and this one collide: rename this one, and add `shell.openTab("update_server")` to the monitor's startup.

### 2. Turtle

One command, at the turtle's home spot (chest behind or beside, not below):

```
wget BASE/miner/install.lua install.lua
install
```

The installer checks modem, pickaxe and fuel, fetches all miner files from the update server and asks four questions: name, mining Y, ore focus, number of corridors (five without GPS: it also asks the home Y level). If the turtle has old miner state it also asks whether this is a new home spot (answer yes when you moved it). With no state left it tells the servers to forget the turtle's old home, so the spot it starts on becomes home. Then it writes the settings and `startup.lua`; `install --default` skips the questions (and keeps old state). Finally reboot, or run `miner`.

No update server? Copy the `miner/*.lua` files onto the turtle by hand (disk or `wget`), then run `install`.

### 3. Monitor

On a computer with a monitor attached:

```
wget BASE/servers/central_monitor.lua central_monitor.lua
wget BASE/servers/startup.lua startup.lua
```

Check the peripheral sides at the top of `startup.lua`, then `reboot`.

### 4. Pocket computer

Needs a wireless (or ender) pocket computer:

```
wget BASE/servers/central_monitor.lua central_monitor.lua
central_monitor
```

It detects that it is a pocket computer and shows the fleet the server sends every 5 s. Commands go through the server.

### Using the monitor

Touch a turtle (or click it on the pocket screen) to see its details and commands. On a basic computer (no mouse) use the arrow keys or Tab to move the `>` marker and Enter to press. Commands to a turtle that is out of range are shown as `queued` and are sent when it is next heard.

| Button | Does |
|--------|------|
| RETURN HOME | Go home, unload, wait `IDLE` |
| PAUSE / RESUME | Stop where it is / carry on (also leaves `IDLE`, `NEEDS_HELP`, and `DONE` after a raise or reset) |
| STATUS | Ask for a status now |
| TARGET Y, FOCUS ORE | Shortcuts for the two most used settings |
| SET... | Pick any remote key (table below), then enter a number on the keypad, choose TRUE/FALSE, or pick the ore |
| UPDATE | Update next time it is home, then carry on |
| RESET JOB | (asks first) Restart the grid at corridor 0 next time it is home |
| RESET HOME | (asks first) "It is at its home now": use the current spot as home |
| REBOOT | (asks first) Save and restart the turtle |

## Comms: modems and range (all automatic)

Nothing to configure: every turtle and computer works out what modem it has (none, basic, ender, wired), how far it is from the server (hops) and whether it is in contact, and keeps checking. Settings only override (`tminer.MODEM`, `tminer.RELAY`). Details in `docs/COMMS.md`.

A basic (wireless) modem reaches 64 blocks at or below Y 96 (more higher up, 384 at build height). A message arrives when either end is in range of the other. An ender modem reaches the whole dimension: if either end has one, the message arrives.

| Setup | What happens |
|-------|--------------|
| No modems | Turtles run blind; keyboard controls on the turtle; no monitor. |
| Basic modems only | Contact near home. About 60 blocks down the shaft a turtle goes out of range: before leaving home it sends `away` with an ETA, the monitor shows `AWAY away, back by ~hh:mm` instead of an alarm, and alerts (`LATE!`) only when it is 50% + 2 min overdue or reports `NEEDS_HELP`/`ERROR`. Commands sent meanwhile are queued and delivered when it is heard again. Events it saw while out of contact (veins, problems) arrive in one catch-up log, merged into the event log at their real times. Turtles near each other relay for each other when that brings a message closer to the server. |
| Basic + a relay computer | `setup relay` on a computer with a basic modem at the shaft bottom covers 64 blocks around it. |
| One ender modem anywhere | On the server, a relay computer or one turtle: every turtle with any modem is in contact everywhere. |
| Wired modems | Every computer running our software relays between all its modems, so wired-only computers (a server deep in a base) reach the turtles through any computer that also has a wireless modem, and separate wired networks joined by one wireless computer work as one network. |
| 4 ender modems on the GPS hosts | GPS fixes at any depth. |

A turtle counts as in contact when it heard a server or relay in the last 30 s. Out of contact it skips its status messages and buffers events (max 50, repeats coalesced); the newest status and the catch-up log go out as soon as contact returns. Everything (server, relay) also runs on basic computers: no colour, mouse, touch or multishell needed.

## Running without a monitor or modem

A turtle works on its own: no modem, no server, no GPS needed. Without a modem it uses `HOME_Y` (the installer asks) and its own move journal for position. Install with `setup.lua turtle` (needs only the HTTP API), then `install`.

Keyboard controls on the turtle's screen (work with or without a monitor):

| Key | Does |
|-----|------|
| `R` | Resume (from PAUSED, IDLE, DONE after raising MAX_CORRIDORS, or NEEDS_HELP) |
| `P` | Pause where it is |
| `B` | Return home and wait |
| `S` | Print phase, reason, position, fuel |
| `H` twice within 5 s | "This spot is home" (same as RESET_HOME) |
| `?` | Show the key list |

Change settings with `set tminer.<KEY> <value>` and reboot. Without a monitor you only see problems on the turtle's own screen; rebooting a turtle in NEEDS_HELP retries.

### Blind turtles (no modem, no GPS)

- **Screen**: the top 5 lines of the turtle's screen are a status block, redrawn on every phase change and every 10 s; log lines scroll below it:

  ```
  MINING                            T1
  (reason, e.g. why it needs help)
  pos -2,-58,-14 f1  fuel 4812
  job c0 b3R s7  ores 42
  --------------------- keys: R P B S H ?
  ```
  `pos` is relative to home (home = 0,HOME_Y,0, `f0` = the way it faced at setup). `LOST` after the position means it no longer trusts it.
- **Crash during a turn** (chunk unloaded, server stopped): the turtle can't tell from fuel whether the turn happened. It turns round once on the spot, looks at all four neighbours and compares them with the cells it knows are open: the tunnel cells its job has finished, every cell in its move journal (always including the one it came from), and the storage next to home. Only when exactly one facing fits does it carry on; caves, ore veins and water/lava count as "unknown", never as evidence. A turn crash in the shaft makes it climb home (vertical moves need no facing) and check against the chest there. In a simulated 2-corridor run, 442 of 448 turn crashes now recover on their own (26 before); the 6 left are turns during the very first home scan, before it has seen its chest.
- **Unlimited fuel**: a move cut off by a crash in open tunnel is settled the same way when the known cells around the two possible spots differ (e.g. it had just moved into fresh rock); walking back through its own tunnel it still asks for help.
- **Still lost?** `NEEDS_HELP` "facing unknown" / "position unknown": carry it home, face it the setup way, press `H` twice. With `SURFACE_IF_LOST` on (off by default) a turtle whose position is lost digs straight up instead (never chests, computers or other protected blocks) until it has passed 8 open cells, hits something unbreakable or protected, or its fuel would drop below 50, and waits there with "lost: surfaced here, carry me home and press H twice". It never does this from home, its shaft column or above home. A GPS turtle tries GPS every 16 blocks on the way up and, once it gets a fix, goes home by itself.
- **Speed**: without a modem nothing waits for the network: no status messages are built, `home_get`, GPS and the update check return at once.

GPS turtles underground: wireless modems reach only 64 blocks (more above Y 96), so at mining depth a GPS turtle usually has no fix. It then recovers exactly like a blind turtle, and after a failed `gps.locate` it doesn't try again (2 s each) until it has climbed 16 blocks or is near home.

## Configuration

Settings live in the turtle's settings file under `tminer.<KEY>`. Change them with `install`, `set tminer.<KEY> <value>` on the turtle, or the monitor's SET... button (keys marked **remote**; the turtle applies them at once and acks or refuses). Restart the miner after a local `set`.

| Key | Default | Remote | Meaning |
|-----|---------|--------|---------|
| `TARGET_Y` | -58 | yes | Mining level (world Y) |
| `HOME_Y` | -9999 (unset) | yes | World Y of the home spot. Only needed without GPS; `install` asks for it. A no-GPS turtle accepts it only while at home |
| `BRANCH_LENGTH` | 32 | yes | Branch length, each side |
| `BRANCH_SPACING` | 3 | yes | Distance between branches (3 = full coverage) |
| `MAIN_LENGTH` | 64 | yes | Length of each corridor's main tunnel |
| `MAX_CORRIDORS` | 8 | yes | Stop with `DONE` after this many corridors |
| `FOCUS` | `all` | yes | `all` or one ore family (`diamond`, `iron`, `ancient_debris`, ...) |
| `VEIN_MINING` | true | yes | Follow ore veins |
| `VEIN_MAX` | 64 | yes | Max blocks per vein |
| `ORES` | (list) | no | Block names counted as ore (`deepslate_` variants included; also `raw_iron/copper/gold_block` from 1.18 large veins, same family as the ore, e.g. `iron`) |
| `TRASH` | (list) | no | Items dropped in the tunnel when nearly full: cobblestone, cobbled deepslate, dirt, gravel, sand, flint, tuff, granite, diorite, andesite, calcite, smooth basalt, basalt, blackstone, netherrack, moss, amethyst block/shard, dripstone |
| `DROP_TRASH` | true | yes | Drop `TRASH` items instead of carrying them home |
| `FUEL_MARGIN` | 200 | yes | Spare fuel kept on top of the distance home |
| `FUEL_KEEP` | 16 | yes | Fuel items kept in reserve, never unloaded |
| `FUEL_TARGET` | 5000 | yes | Refuel up to this at home if there is a fuel chest |
| `BURN_COAL` | true | yes | Burn mined coal when fuel is below `FUEL_TARGET` |
| `STATUS_INTERVAL` | 10 | yes | Seconds between status messages |
| `SNAPSHOT_EVERY` | 100 | no | Moves between full state snapshots |
| `STUCK_TIMEOUT` | 60 | no | Seconds without progress before a move gives up |
| `HELP_RETRY` | 30 | no | Seconds between automatic retries while `NEEDS_HELP` ("stuck" retries wait 4x this) |
| `AUTO_UPDATE` | true | yes | Check for updates at boot when at home |
| `SURFACE_IF_LOST` | false | yes | Position lost after a crash: dig straight up to the surface and wait there (see "Blind turtles") |
| `RELAY` | `auto` | no | Relay other turtles' messages: `auto` (ender modem: always; basic: when it moves a message closer), `on`, `off` |
| `MODEM` | `auto` | no | Own modem kind, normally detected: `basic` or `ender` overrides (also read by `relay` and the monitor) |

Grid settings (`BRANCH_LENGTH`, `BRANCH_SPACING`, `MAIN_LENGTH`) are frozen into the job when it starts; new values apply after `RESET_JOB`. `MAX_CORRIDORS`, `TARGET_Y` and `FOCUS` apply at once.

## Phases

| Phase | Meaning |
|-------|---------|
| `BOOT`, `RECOVER` | Starting up, working out where it is after a restart |
| `TO_WORK` | Walking from home to the next branch |
| `MINING`, `VEIN` | Digging a branch / following an ore vein |
| `RETURNING` | Going home (inventory full, fuel low, or told to) |
| `UNLOADING`, `REFUELING` | At home, emptying into the chest / topping up fuel |
| `IDLE` | At home, waiting (after `RETURN_HOME`); send `RESUME` |
| `PAUSED` | Stopped where it is by `PAUSE`; stays paused in place across reboots and chunk reloads; send `RESUME` |
| `DONE` | Mined `MAX_CORRIDORS` corridors. Raise `MAX_CORRIDORS` (SET) and send `RESUME` to mine more, or send `RESET_JOB` then `RESUME` to start the grid over |
| `ERROR` | The program crashed; it saves, tries to go home, then `NEEDS_HELP` |
| `NEEDS_HELP` | It can't continue on its own. The reason says why (below) |

`NEEDS_HELP` reasons:

| Reason | What to do |
|--------|-----------|
| chest full / `storage_full` | Empty the home chest. It retries every 30 s by itself |
| no storage / `no_storage` | Put a chest behind or beside the home spot |
| no GPS: set HOME_Y | Turtle has no GPS and doesn't know its Y. Send `SET HOME_Y <y>` then `RESUME` (or rerun `install`). `SET HOME_Y` is refused unless the turtle is at home |
| stuck: unbreakable at x,y,z | Bedrock or a protected block in the way. Change `TARGET_Y` or send `RESET_JOB`, then `RESUME` |
| no fuel / `no_fuel` | Bring fuel to the turtle (or to its chest at home), then `RESUME`. When stranded on the way home it also burns its `FUEL_KEEP` reserve |
| stuck: timeout ... retry n/5 | Something kept blocking it for 60 s (mob, player, other turtle). It goes back to work by itself every 2 minutes, 5 times; after that ("gave up") clear the way and `RESUME` |
| facing unknown after crash (probe: n facings fit) | Crashed mid-turn without a GPS fix and the four neighbours did not tell which way it faces (open cave, unknown cells). Carry it home, face it the setup way, press `H` twice or send `RESET_HOME` |
| lost: surfaced here, carry me home and press H twice | `SURFACE_IF_LOST` climbed it to the surface. Do what it says |
| position unknown after crash | Same: put it at home and send `RESET_HOME` |
| state lost: send RESET_HOME here or carry to home | GPS turtle lost its state files and is far from the home the server remembers. If this spot is its new home, send `RESET_HOME`. If not, carry it to its old home: it notices and carries on |
| state lost: place at home and send RESET_HOME | Same without GPS: put it at home, send `RESET_HOME` |
| ERROR text | A bug. The card shows the first 200 characters of the traceback; report it |

## Troubleshooting

- **Turtle not on the monitor**: does it have a modem (`peripheral.find("modem")`)? Is it in range, or is an ender modem needed? A turtle silent for 60 s shows as `SILENT`.
- **Commands go to the wrong turtle**: they can't; commands carry the turtle's ID. Check the label/ID on the card.
- **Turtle won't update**: updates only run at boot while the turtle is at home, or after `UPDATE` the next time it is home (then it carries on with what it was doing). Run `updater --check` on the turtle to see what the server offers. The server needs the higher version number on the first line.
- **A broken file on the server**: the turtle checks every file with `load()` before installing and keeps the old one if any file fails. The previous version stays as `<name>.bak`.
- **Boot loop after an update**: can't happen by design: the turtle reboots at most once per update (`.tm_updated` marks it). Disable auto-updates with `set tminer.AUTO_UPDATE false`.
- **Moved the turtle by hand / lost state**: put it on its home spot and send `RESET_HOME`. To set it up somewhere new, run `install` there and answer yes to "new home spot" (it deletes `.tm_state*` and `.tm_journal*` and makes the servers forget the old home). By hand: delete those files, delete the turtle's entry from `miner_homes.db` on every monitor server (or run `install`), and reboot.
- **Start over**: `RESET JOB` on the monitor restarts the grid at corridor 0 next time the turtle is home; `RESUME` if it is `DONE` or `IDLE`.
- **Paused turtle after a server restart**: it stays `PAUSED` where it was. Send `RESUME`, or `RETURN_HOME`.
