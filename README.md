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
- **Optional GPS** (4 GPS hosts). With GPS the turtle uses world coordinates and re-checks its position; without GPS it counts moves from home. Each turtle decides at boot.
- **Server computer** with a wireless/ender modem. If turtles are far away, use ender modems, or several modems on the server (it relays `TMINER` messages between them).

Keep the home and mining area chunk-loaded if you can. If not, the turtle resumes when the chunk loads again.

## Install

The examples use `wget` from GitHub; copying from a floppy disk works the same way. CC has no shell variables: wherever you see `BASE`, type `https://raw.githubusercontent.com/wallcop100/TurtleMiner/main`.

### 1. Update server (do this first)

On the server computer:

```
wget BASE/servers/update_server/update_server.lua update_server.lua
wget BASE/servers/update_server/startup.lua startup.lua
mkdir /files
```

Copy every file from `miner/` into `/files/` (`config.lua`, `state.lua`, `nav.lua`, `inv.lua`, `mine.lua`, `net.lua`, `miner.lua`, `updater.lua`, `install.lua`, `startup.lua`), e.g. `wget BASE/miner/nav.lua /files/nav.lua`. Then `reboot`.

The server reads the version from each file's first line (`-- Version: x.y.z`) and serves the files to turtles that ask. To roll out a change, bump the version line and drop the file in `/files/`: no restart needed. Turtles pick it up the next time they boot at home, or when you send `UPDATE`. A folder `/files/miner/`, if present, is used instead of `/files/` for miners.

If the monitor runs on the same computer, its `startup.lua` and this one collide: rename this one, and add `shell.openTab("update_server")` to the monitor's startup.

### 2. Turtle

One command, at the turtle's home spot (chest behind or beside, not below):

```
wget run https://raw.githubusercontent.com/wallcop100/TurtleMiner/main/miner/install.lua
```

The installer checks modem, pickaxe and fuel, fetches all miner files from the update server, asks four questions (name, mining Y, ore focus, number of corridors), writes the settings and `startup.lua`. `install --default` skips the questions. Then reboot, or run `miner`.

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

## Configuration

Settings live in the turtle's settings file under `tminer.<KEY>`. Change them with `install`, `set tminer.<KEY> <value>` on the turtle, or the monitor's SET command (keys marked **remote**). Restart the miner after a local `set`.

| Key | Default | Remote | Meaning |
|-----|---------|--------|---------|
| `TARGET_Y` | -58 | yes | Mining level (world Y) |
| `HOME_Y` | -9999 (unset) | yes | World Y of the home spot. Only needed without GPS; `install` asks for it |
| `BRANCH_LENGTH` | 32 | yes | Branch length, each side |
| `BRANCH_SPACING` | 3 | yes | Distance between branches (3 = full coverage) |
| `MAIN_LENGTH` | 64 | yes | Length of each corridor's main tunnel |
| `MAX_CORRIDORS` | 8 | yes | Stop with `DONE` after this many corridors |
| `FOCUS` | `all` | yes | `all` or one ore family (`diamond`, `iron`, `ancient_debris`, ...) |
| `VEIN_MINING` | true | yes | Follow ore veins |
| `VEIN_MAX` | 64 | yes | Max blocks per vein |
| `ORES` | (list) | no | Block names counted as ore (`deepslate_` variants included) |
| `TRASH` | (list) | no | Items dropped in the tunnel when nearly full |
| `DROP_TRASH` | true | yes | Drop `TRASH` items instead of carrying them home |
| `FUEL_MARGIN` | 200 | yes | Spare fuel kept on top of the distance home |
| `FUEL_KEEP` | 16 | yes | Fuel items kept in reserve, never unloaded |
| `FUEL_TARGET` | 5000 | yes | Refuel up to this at home if there is a fuel chest |
| `BURN_COAL` | true | yes | Burn mined coal when fuel is below `FUEL_TARGET` |
| `STATUS_INTERVAL` | 10 | yes | Seconds between status messages |
| `SNAPSHOT_EVERY` | 100 | no | Moves between full state snapshots |
| `STUCK_TIMEOUT` | 60 | no | Seconds without progress before a move gives up |
| `HELP_RETRY` | 30 | no | Seconds between automatic retries while `NEEDS_HELP` |
| `AUTO_UPDATE` | true | yes | Check for updates at boot when at home |

## Phases

| Phase | Meaning |
|-------|---------|
| `BOOT`, `RECOVER` | Starting up, working out where it is after a restart |
| `TO_WORK` | Walking from home to the next branch |
| `MINING`, `VEIN` | Digging a branch / following an ore vein |
| `RETURNING` | Going home (inventory full, fuel low, or told to) |
| `UNLOADING`, `REFUELING` | At home, emptying into the chest / topping up fuel |
| `IDLE` | At home, waiting (after `RETURN_HOME`) |
| `PAUSED` | Stopped where it is by `PAUSE`; send `RESUME` |
| `DONE` | Mined `MAX_CORRIDORS` corridors. Raise it, or send `RESET_JOB` |
| `ERROR` | The program crashed; it saves, tries to go home, then `NEEDS_HELP` |
| `NEEDS_HELP` | It can't continue on its own. The reason says why (below) |

`NEEDS_HELP` reasons:

| Reason | What to do |
|--------|-----------|
| chest full / `storage_full` | Empty the home chest. It retries every 30 s by itself |
| no storage / `no_storage` | Put a chest behind or beside the home spot |
| no GPS: set HOME_Y | Turtle has no GPS and doesn't know its Y. Send `SET HOME_Y <y>` then `RESUME` (or rerun `install`) |
| unbreakable block at x,y,z | Bedrock or a protected block in the way. Change `TARGET_Y` or send `RESET_JOB`, then `RESUME` |
| no fuel / `no_fuel` | Bring fuel to the turtle (or to its chest at home), then `RESUME` |
| timeout | Something kept blocking it for 60 s (mob farm, other turtle). Clear it, `RESUME` |
| facing unknown after crash | Crashed mid-turn without GPS. Carry it home, face it the setup way, send `RESET_HOME` |
| position unknown after crash / state lost | Same: put it at home and send `RESET_HOME` |
| ERROR text | A bug. The card shows the first 200 characters of the traceback; report it |

## Troubleshooting

- **Turtle not on the monitor**: does it have a modem (`peripheral.find("modem")`)? Is it in range, or is an ender modem needed? A turtle silent for 60 s shows as `SILENT`.
- **Commands go to the wrong turtle**: they can't; commands carry the turtle's ID. Check the label/ID on the card.
- **Turtle won't update**: updates only run at boot while the turtle is at home (or via `UPDATE` when idle at home). Run `updater --check` on the turtle to see what the server offers. The server needs the higher version number on the first line.
- **A broken file on the server**: the turtle checks every file with `load()` before installing and keeps the old one if any file fails. The previous version stays as `<name>.bak`.
- **Boot loop after an update**: can't happen by design: the turtle reboots at most once per update (`.tm_updated` marks it). Disable auto-updates with `set tminer.AUTO_UPDATE false`.
- **Moved the turtle by hand / lost state**: put it on its home spot and send `RESET_HOME`, or delete `.tm_state*` and `.tm_journal` on the turtle and reboot (it then treats where it is as home).
- **Start over**: `RESET_JOB` from the monitor restarts the grid at corridor 0 next time the turtle is home.
