# TurtleMiner

Branch mining for CC:Tweaked turtles that keeps going on its own. Turtles save their position before every move, survive server restarts and chunk unloads, burn the coal they find, and say plainly when they need help. A monitor (computer screen, monitor wall or pocket computer) shows the whole fleet and sends commands. It works with no modem at all, basic modems, ender modems, wired networks, or any mix, on basic or advanced hardware. Everything is detected automatically; settings only override.

> Status: the turtle, monitor, comms, update server, server clustering and the mining network (signed messages) are done and tested in a simulator (56 scenarios). **The GPS setup offer and mesh updates are being built** (sections marked *coming*). Nothing here has been signed off in a live world yet; please report what you see.

Contents: [Quick start](#quick-start) · [What you need](#what-you-need) · [Install](#install) · [Using it](#using-it) · [Networking](#networking) · [GPS](#gps) · [Clustering](#clustering) · [Mining network](#mining-network) · [Updates](#updates) · [Settings](#settings) · [Phases and help messages](#phases-and-help-messages) · [Troubleshooting](#troubleshooting) · [For developers](#for-developers)

---

## Quick start

All commands need CC's HTTP API (on by default). `BASE` below means `https://raw.githubusercontent.com/wallcop100/TurtleMiner/claude/vigilant-pasteur-g2krss` (will become `.../main` once merged).

1. **Main computer** (with a modem; a monitor is optional):
   ```
   wget run BASE/setup.lua server
   reboot
   ```
   Setup asks you to **create a mining network** and shows its 4-word join phrase: write it down (see [Mining network](#mining-network)).
2. **Each turtle**, standing on its home spot with a chest behind or beside it:
   ```
   wget BASE/miner/install.lua install.lua
   install
   ```
   Join the network first (type the 4 words, use a floppy disk, or approve it on the monitor), then answer the questions (name, mining Y, ore, corridors, and the home Y if there's no GPS). It starts mining after a reboot. `install` fetches its network files (`tmcrypto`, `tmwords`, `tmjoin`) from GitHub when they're missing.
3. **Optional**: a pocket computer (`wget run BASE/setup.lua pocket`), extra monitor computers (`... monitor`), relay computers (`... relay`).

No server at all? On the turtle: `wget run BASE/setup.lua turtle`, then `install`.

If GitHub serves an old file right after an update, add `?v=2` (any number) to the URL to skip its 5-minute cache.

---

## What you need

### Turtle
- Any mining turtle, basic or advanced (advanced turtles hold 100 000 fuel instead of 20 000; the miner reads the real limit).
- A **pickaxe** equipped. A **modem** on the other side is optional: wireless (basic), ender, or none.
- Some fuel to start (coal in its inventory is fine). It burns the coal it mines from then on.

### Home spot
- The turtle's starting block is home. The shaft goes **straight down** from it.
- A **chest** (or barrel, shulker box) **behind or beside** the turtle. **Not below** (that's the shaft) and **not on the modem's side** (the turtle can't see a chest there).
- Optional **fuel chest**: a second chest holding mostly coal/charcoal. Detected automatically; the turtle tops up from it.
- A turtle that gets a GPS fix at home works out which way it faces by stepping once: leave one free block in front, behind, or above (with a free block in front of that one). Without GPS this isn't needed.

### Space
- With the defaults a turtle mines a big area: down to `TARGET_Y`, then a spine to the **right** of the way it faced at setup, up to `MAX_CORRIDORS × (2×BRANCH_LENGTH + BRANCH_SPACING)` = 536 blocks, with 64-block corridors forward and 32-block branches each side.
- **Chunks**: turtles only work in loaded chunks. If you walk away, a turtle freezes and resumes where it was when the chunk loads again. Lower `MAX_CORRIDORS` / `BRANCH_LENGTH` to keep the area near you.
- **Several turtles**: their areas must not overlap. Space homes further apart than the area above, or face them in different directions. (Shared tunnels for a group of turtles are planned: see `docs/ARMY_PLAN.md`.)
- Turtles **attack anything in their way**, players included. Don't stand in the tunnels.

### Computers (optional)
Any computer, basic or advanced. A monitor of any size (touch on advanced monitors, keyboard on basic). A pocket computer with a modem. Nothing needs colour, a mouse or multishell.

---

## Install

`setup.lua` downloads the right files for each device. Run it with one of these roles:

| Role | Use on | Installs | Starts at boot |
|------|--------|----------|----------------|
| `server` | Any server computer | `tminer_server` (roles detected automatically) + miner files in `/files/` for serving updates | `tminer_server` |
| `monitor` | Another server computer | Same program, without `/files/` | `tminer_server` |
| `pocket` | Pocket computer | Same program; runs as a phone-sized client | `tminer_server` |
| `relay` | Any spare computer | `relay.lua` | Relay |
| `turtle` | A turtle with no server around | All miner files | (run `install` next) |

```
wget run BASE/setup.lua <role>
reboot
```

Running it again updates the files. If something can't be written, it says why: a folder in the way, read-only, or the disk is full (each computer has about 1 MB). A plain file sitting where a folder is needed is moved to `<name>.old`.

### Turtle: `install`
Run on the turtle, at its home spot:
```
wget BASE/miner/install.lua install.lua
install
```
It:
0. Joins the mining network (required, once): create, type the 4 words, take it from a disk, or ask the monitor to approve.
1. Checks for a pickaxe, a modem (optional) and fuel.
2. Fetches any missing miner files from the update server (or tells you to run `setup turtle` if there isn't one).
3. Asks: name, mining Y (`TARGET_Y`), ore focus, corridors before stopping, and the **home Y** if it can't get a GPS fix (read it from F3; it must be the turtle's own block).
4. If old miner state exists, asks whether this is a **new home spot**. Yes clears the old state and tells the servers to forget the old home.
5. Writes the settings and `startup.lua`.

`install --default` skips the questions (with a network already joined, or `--join <4 words>` / `--create`). `install --network` only changes the network.

### Manual install
Copy the files yourself (disk or `wget`), e.g. `wget BASE/miner/nav.lua nav.lua`.
- Turtle: everything in `miner/` to the turtle's root, then `install`.
- Server: `servers/tminer_server.lua`, `servers/tm_*.lua`, `servers/central_monitor.lua`, `servers/update_server/github_pull.lua`, `servers/startup.lua` (as `tminer_startup.lua`), `miner/tmcrypto.lua`, `miner/tmwords.lua`, `miner/tmjoin.lua` (to the root), and `miner/*` into `/files/`. `startup.lua` is one line: `shell.run("tminer_startup")`. Then copy `setup.lua` too and run `setup network` to join the network.
- Relay: `servers/relay.lua` plus the three `miner/tm*.lua` network files.

---

## Using it

### The monitor
Shows every turtle: phase, reason, fuel against what it needs to get home, distance, position, job, ores, last seen, last error. Problem turtles (`NEEDS_HELP`, `ERROR`, overdue) go to the top, marked `!`, red on colour screens, with a beep if a speaker is attached.

Open a turtle with touch (advanced monitor), click (advanced computer/pocket), or the keyboard (arrows/Tab move the `>` marker, Enter presses). Commands to a turtle that's out of range show `queued` and are delivered when it's next heard.

| Button | Does |
|--------|------|
| RETURN HOME | Go home, unload, wait (`IDLE`) |
| PAUSE / RESUME | Stop where it is / carry on (also leaves `IDLE`, `NEEDS_HELP`, and `DONE` after raising `MAX_CORRIDORS` or a reset) |
| STATUS | Ask for a status now |
| TARGET Y, FOCUS ORE | Shortcuts for the two most used settings |
| SET... | Change any remote setting (list under [Settings](#settings)) |
| UPDATE | Update next time it's home, then carry on |
| RESET JOB | (asks first) Start the grid over at corridor 0 next time it's home |
| RESET HOME | (asks first) "It's at its home now": use the current spot as home |
| REBOOT | (asks first) Save and restart the turtle |

The event log is kept in `miner_events.log` on the server (last 500 lines).

### The turtle's own screen and keys
Top of the turtle's screen:
```
MINING                            T1
(reason, e.g. why it needs help)
pos -2,-58,-14 f1  fuel 4812
job c0 b3R s7  ores 42
--------------------- keys: R P B S H ?
```
`pos` is world coordinates with GPS, otherwise relative to home (`0,HOME_Y,0`, `f0` = the way it faced at setup). `LOST` means it no longer trusts its position.

| Key | Does |
|-----|------|
| `R` | Resume |
| `P` | Pause where it is |
| `B` | Return home and wait |
| `S` | Print phase, reason, position, fuel |
| `H` twice within 5 s | "This spot is home" (same as RESET HOME) |
| `?` | Show the keys |

These work with or without a monitor, so a turtle with no modem is fully usable.

### How a turtle mines
- Digs a 1×1 shaft from home to `TARGET_Y`, then a spine to the right, corridors forward from the spine, and branches to both sides every `BRANCH_SPACING` blocks (3 = every block of rock is seen).
- On every new block it checks all faces for ore (`deepslate_` variants and 1.18 raw ore blocks count; modded ores tagged `c:ores`/`forge:ores` too). With `VEIN_MINING` it follows the vein, then backs out the way it came.
- Drops junk (`TRASH`) in the tunnel when nearly full; heads home when full or when fuel gets close to what it needs to get back along its real tunnel route.
- At home: burns coal up to `FUEL_TARGET`, keeps `FUEL_KEEP` fuel items, sends extra fuel to the fuel chest, and unloads everything else.
- Walks home through its own tunnels and never digs chests, barrels, shulkers, computers or other turtles. Gravel, falling dripstone and mobs are waited out; lava and water don't stop it.

### Crash and unload recovery
Every move and turn is written to a journal before it happens. After a restart the turtle works out where it is from the journal, its fuel (each move costs exactly 1), the block in front, GPS if it can get a fix here, and if needed by looking round at its four neighbours and matching them against the tunnels it knows. In a simulated run, 442 of 448 crashes mid-turn recovered with no GPS. When it can't be sure, it stops and says so (`NEEDS_HELP`), it never guesses. Optional `SURFACE_IF_LOST` makes a lost turtle dig straight up to the surface and wait there instead.

---

## Networking

Everything here is automatic. Each device works out which modem it has, who it can reach and how many hops away the server is, and keeps re-checking. Full details: `docs/COMMS.md`.

### Modem range (CC:Tweaked rules)
| Modem | Range |
|-------|-------|
| None | Turtle works alone; keys on its screen |
| Wireless (basic) | 64 blocks at or below Y 96, rising to 384 at build height. Straight-line distance, walls don't matter. A message arrives if **either** end is in range |
| Ender | The whole dimension (and other dimensions). If **either** end has one, the message arrives |
| Wired | Only along the cable network |

What that means: with a home around Y 70 and mining at Y -58, a turtle with a basic modem loses contact about 60 blocks down the shaft. Putting the server higher doesn't fix it (it's straight-line distance).

### Out of range is normal
- Before leaving home a turtle sends `away` with an ETA. The monitor shows `AWAY back by ~hh:mm` and only alerts (`OVERDUE`, shown as `LATE!`) if it's 50% + 2 minutes overdue, or reports a problem.
- Commands sent while it's away are **queued** on the server and delivered the moment it's heard again (kept 24 h; a newer command of the same kind replaces an older one).
- Events it saw while away (veins, problems) come back as one **catch-up log**, filed under the time they happened.
- Out of contact it doesn't waste time sending status; the newest status goes out as soon as it's back.

### Mesh: every computer is a bridge
- Every computer running TurtleMiner (server, monitor, relay) passes `TMINER` messages between **all** its modems: wired, wireless and ender. Duplicates are dropped and there's a hop limit, so there are no loops.
- So a wired-only computer deep in your base reaches the turtles through any computer that also has a wireless modem, and two wired networks joined by one wireless computer act as one network.
- Turtles relay for each other too: a turtle with an ender modem always relays; one with a basic modem relays only when that brings a message closer to its destination (in the simulator, 10 basic turtles used about 2 transmissions per message instead of about 12).
- `relay` program: put a spare computer with a basic modem at the shaft bottom for contact 64 blocks around it, or one with an ender modem anywhere for contact everywhere.

### What to expect
| You have | You get |
|----------|---------|
| No modems | Turtles mine; you use their keys. No monitor |
| Basic modems | Contact near home; `AWAY`, queued commands and catch-up logs cover the rest |
| Basic + a relay at the shaft bottom | Contact 64 blocks around the relay too |
| One ender modem anywhere (server, relay or a turtle) | Every turtle with any modem in contact everywhere |
| Wired + wireless computers | One network; wired-only computers fully take part |

---

## GPS

GPS is optional and used whenever it's available "here, now". Turtles never depend on it.

### How CC's GPS works
- A GPS host is a computer with a **wireless or ender modem** that knows its own exact coordinates and runs `gps host`. Wired modems can't do it (they don't measure distance).
- A turtle asks; each host in range replies, and the game tells the turtle how far away each reply came from. From the distances it works out its position.
- You need **at least 4 hosts**, not all at the same height and not in a line. With 3 there are two possible answers and `gps.locate` gives up.
- Range is the modem range above. Hosts with **basic** modems on a surface tower don't reach Y -58; hosts with **ender** modems reach everywhere.

### What turtles do with it
- At boot, at home, after a crash and while surfacing, a turtle tries for a fix. With one it uses world coordinates and checks its position; without one it carries on from its journal.
- After a failed attempt it doesn't try again (each try waits 2 s) until it has climbed 16 blocks or is back near home.
- A turtle that had GPS at the surface and none at depth recovers from crashes exactly like a blind turtle.

### Setting up hosts today
Use 4 computers, each with its own wireless (or ender) modem, spread out and at different heights. On each, type its block's coordinates from F3:
```
gps host <x> <y> <z>
```
(Put that line in its `startup.lua` to survive reboots.) Test with `gps locate` on a pocket computer.

### GPS offer *(coming)*
The server cluster will do this for you. When it sees at least 4 computers with wireless/ender modems laid out well enough for GPS, it offers `GPS possible with 4 PCs: [Set up] [Later] [Never]` on the monitor and on each of those computers. One "Set up" configures all of them. It measures their positions itself from modem distances (silently, if any computer already gets a GPS fix or GPS turtles pass nearby), and only falls back to asking for F3 coordinates, on that computer's own screen, for as few computers as needed, checking each entry against the measured distances to catch typos. Hosts re-check each other every 10 minutes; one that has moved or breaks stops hosting rather than give wrong positions. If there aren't enough suitable computers it stays quiet. Plan: `docs/CLUSTER_GPS_PLAN.md`.

---

## Clustering

Every server computer runs the same program, `tminer_server` (`setup server`, or `setup monitor` for one without update files). Nothing to configure.

**Roles are automatic**, checked at boot, every minute and when you attach or remove something:

| The computer has | It does |
|------------------|---------|
| A monitor (or it's a pocket) | Shows the UI |
| A wireless or ender modem | Talks to turtles, relays for the mesh |
| A wired modem | Links to the other server computers |
| A `/files/` folder | Serves updates to turtles, pulls from GitHub |
| (always) | Keeps a copy of the cluster's records |

**One cluster.** Server computers find each other over any mix of wired and wireless links (separate wired networks joined by a computer with both kinds become one cluster). One computer is the **leader**: normally the lowest computer ID when they start together. It holds the records (turtle homes, queued commands, away times, event log), answers the turtles and sends the commands. The others keep a copy, updated within half a second of a change and at least every 5 s.

- **Commands from anywhere:** any computer's screen or a pocket. They go to the leader and are applied once.
- **Failover:** if the leader is switched off, another computer takes over within about 17 s, with nothing lost; commands typed meanwhile are delivered once. The old leader rejoins as a copy.
- **Healed splits:** if a cable is cut and later reconnected, the two halves merge back into one leader and hand over what they queued.
- **Wired-only computers** take full part through any computer with a wireless or ender modem.
- The screen footer shows the cluster: `LEAD 3pc` on the leader, `ldr#10 3pc` on the others.

Example: 3 computers on one cable, one with a wireless modem. All three run `tminer_server`; the wireless one talks to the turtles, and you can use any of their screens.

**Keyboard on basic hardware:** Tab or arrows move, Enter selects, Backspace goes back, digits type numbers. A basic monitor (no touch) follows the keyboard.

Older installs upgrade themselves through the GitHub pull: `central_monitor` still works (it now starts `tminer_server`), and the old `update_server` steps aside.

## Mining network

Every device (turtles, server PCs, monitors, pockets, relays) belongs to one **mining network**. Every message is signed with the network's secret key, so other players on the same server can't command your turtles, fake their status, or answer as your update server. Several players' networks share the airwaves without seeing each other.

**Joining** happens once, at install (`install` on a turtle, `setup` on a computer), and is required:

- **Create** a new network on the first device. It shows a **join phrase of 4 words**, e.g. `ghast marina cairn peak`. Write them down. Optionally give the network a name (default `mine`); the name is part of the key, so other devices need it too.
- **Join by typing** the 4 words on each other device. Case, spaces and punctuation don't matter; a mistyped word gets "did you mean ...".
- **Join from a floppy disk** (no typing): on any network device, copy the network to a disk in a drive next to it (monitor: **NET → TO DISK**; turtle: press `N`; computer: `setup network --to-disk`). Put the disk in a drive next to the new device and run `install` / `setup`: it offers to use it, then to wipe it. Keep that disk safe; it is the key.
- **Approve on the monitor**: choose "approve" on the new device (`install --approve`, `setup <role> --approve`). The monitor footer shows `JOIN?`; open **NET** and press **OK #id** within 2 minutes. The key then goes over the air unencrypted, so this is only safe when nobody else is listening at that moment. Prefer the disk or typing.

Without questions: `install --default --join <4 words> [--name <name>]`, `install --default --create [name]`, `--disk [--wipe-disk]`, `--approve`; the same flags work for `setup <role>`.

**Later:** `install --network` (turtle) or `setup network` (computer) joins another network; reboot afterwards. The monitor's **NET** screen shows the network name, the count of foreign/bad messages dropped, join requests, and (after a confirmation) the 4 words. The footer shows `bad:n` when foreign or forged messages were dropped, `NO NETWORK` when the PC has none.

**What it protects:** commands, status, homes, the cluster's data and updates. A message that is unsigned, signed with another key, changed on the way, replayed, or more than 10 minutes old or in the future is dropped and never relayed. The turtle's updater only installs files from its own network's update server.

**What it doesn't:** GPS (CC's GPS protocol can't be signed; a fake GPS host could still give wrong positions; turtles check fixes against their journal), and anyone who learns the 4 words, gets the disk, or is listening during an approve. The words come from a 1024-word list (about 40 bits) and the key is derived slowly, but CC has no strong random source: don't reuse a phrase you've shown in public. Messages are signed, not encrypted: others can still read them.

**Upgrading an older install:** after updating to this version every device needs the network once (`setup network` on computers, `install --network` on turtles); until then it works offline and says "no mining network".

Cost: signing a status message takes about 9 SHA-256 blocks (a few ms); joining derives the key once (about 1 s). Turtles without a modem do no signing at all.

### Mesh updates *(coming)*

Planned (`docs/MESH_UPDATE_PLAN.md`): updates spread device to device over the mesh: pull from GitHub (hourly, at boot, or **Check now** on the monitor) or edit a file by hand on any computer, and every device updates itself (turtles at home, computers when idle, one reboot each). An update that makes a device crash is rolled back automatically and blocked across the network.

---

## Updates

- The **update server** (part of `setup server`) serves the files in `/files/` to turtles. Each file's first line is `-- Version: x.y.z`; a turtle installs a file only if the server's version is higher, after checking it loads. If any file fails, nothing is replaced. The old file stays as `<name>.bak`.
- Turtles update **only at home**: at boot, or after `UPDATE` (next time they're home, then they carry on). They reboot at most once per update.
- **GitHub auto-pull**: the update server checks GitHub at boot and every 60 minutes and copies in any newer file that compiles, including its own programs (then it reboots once). Settings on the server computer:
  - `set tminer.pull_minutes 0`: only at boot
  - `set tminer.auto_pull false`: off
  - `set tminer.repo_base <raw URL ending in />`: another branch, e.g. `main` after merging
- Pocket computers and extra monitors don't auto-pull: re-run their `setup` line.
- Check what a turtle would get: `updater --check` on the turtle.

---

## Settings

Turtle settings live under `tminer.<KEY>`. Change them with `install`, `set tminer.<KEY> <value>` on the turtle (then reboot), or SET... on the monitor (applied at once; the turtle accepts or refuses).

| Key | Default | Remote | Meaning |
|-----|---------|--------|---------|
| `TARGET_Y` | -58 | yes | Mining level (world Y) |
| `HOME_Y` | unset | yes | World Y of the home spot, needed only without GPS (`install` asks). Accepted only while the turtle is at home |
| `BRANCH_LENGTH` | 32 | yes | Branch length each side |
| `BRANCH_SPACING` | 3 | yes | Distance between branches (3 = full coverage) |
| `MAIN_LENGTH` | 64 | yes | Corridor length |
| `MAX_CORRIDORS` | 8 | yes | Stop with `DONE` after this many |
| `FOCUS` | `all` | yes | `all` or one ore family: `diamond`, `iron`, `ancient_debris`, … |
| `VEIN_MINING` | true | yes | Follow ore veins |
| `VEIN_MAX` | 64 | yes | Max blocks per vein |
| `DROP_TRASH` | true | yes | Drop junk in the tunnel instead of carrying it home |
| `FUEL_MARGIN` | 200 | yes | Spare fuel on top of the route home |
| `FUEL_KEEP` | 16 | yes | Fuel items always kept (burned only when stranded) |
| `FUEL_TARGET` | 5000 | yes | Refuel to this at home |
| `BURN_COAL` | true | yes | Burn mined coal below `FUEL_TARGET` |
| `STATUS_INTERVAL` | 10 | yes | Seconds between status messages (in contact) |
| `AUTO_UPDATE` | true | yes | Check for updates at boot when at home |
| `SURFACE_IF_LOST` | false | yes | Lost position: dig up to the surface and wait |
| `SNAPSHOT_EVERY` | 100 | no | Moves between full state saves (the journal covers the rest) |
| `STUCK_TIMEOUT` | 60 | no | Seconds without progress before a move gives up |
| `HELP_RETRY` | 30 | no | Seconds between automatic retries in `NEEDS_HELP` |
| `RELAY` | `auto` | no | Relay others' messages: `auto`, `on`, `off` |
| `MODEM` | `auto` | no | Own modem kind if detection is wrong: `basic`, `ender` |
| `ORES`, `TRASH` | lists | no | Block names counted as ore / items dropped as junk (see `miner/config.lua`) |

`BRANCH_LENGTH`, `BRANCH_SPACING` and `MAIN_LENGTH` are fixed for a job when it starts (new values after RESET JOB). Others apply at once.

---

## Phases and help messages

| Phase | Meaning |
|-------|---------|
| `BOOT`, `RECOVER` | Starting, working out where it is |
| `TO_WORK` | Going to its next branch |
| `MINING`, `VEIN` | Digging / following a vein |
| `RETURNING` | Going home (full, fuel, or told to) |
| `UNLOADING`, `REFUELING` | At home |
| `IDLE` | At home waiting; RESUME (or `R`) |
| `PAUSED` | Stopped in place, also across reboots; RESUME |
| `DONE` | Finished `MAX_CORRIDORS`. Raise it and RESUME, or RESET JOB then RESUME |
| `AWAY` (monitor only) | Out of range on a trip; back by the time shown |
| `ERROR` | Program crashed; it saves, tries to go home, then `NEEDS_HELP` |
| `NEEDS_HELP` | Needs you; the reason says why |

| `NEEDS_HELP` reason | What to do |
|---------------------|-----------|
| storage full | Empty the home chest; it retries every 30 s |
| no storage at home | Put a chest behind or beside home (not below, not on the modem side) |
| no GPS: set HOME_Y | SET `HOME_Y` (at home) then RESUME, or rerun `install` |
| stuck: unbreakable at x,y,z | Bedrock or a protected block in the way: change `TARGET_Y` or RESET JOB, then RESUME |
| stuck: timeout … retry n/5 | Something blocked it for 60 s; it retries every 2 min, 5 times. After "gave up", clear the way and RESUME |
| out of fuel / no_fuel | Bring fuel to it or its chest, RESUME |
| facing unknown after crash / position unknown after crash | Carry it home, face it the setup way, press `H` twice (or RESET HOME) |
| lost: surfaced here … | `SURFACE_IF_LOST` brought it up: carry it home, `H` twice |
| state lost: send RESET_HOME here or carry to home | Its save files are gone. New home here: RESET HOME. Otherwise carry it to its old home (with GPS it notices by itself) |
| ERROR text | A bug: the card shows the start of the error; please report it |

---

## Troubleshooting

- **`setup` fails**: read the `failed:` line (folder in the way, read-only, disk full). Make sure you're running the current `setup.lua` (`wget run …`, not an old saved copy).
- **Turtle not on the monitor**: does it have a modem? It may just be out of range (`AWAY`). Basic modems reach 64 blocks; use a relay or an ender modem for more.
- **Monitor shows `LATE!`**: the turtle is well past its expected return. Check its screen or go and look; commands are queued meanwhile.
- **Commands affect the wrong turtle**: they can't; each command carries the turtle's ID.
- **Turtle doesn't update**: it updates only at home. `updater --check` shows what the server offers; the server needs a higher version on the file's first line.
- **Moved a turtle by hand**: put it on its home spot and press `H` twice (or RESET HOME). For a new home, run `install` there and answer yes to "new home spot".
- **Start over**: RESET JOB, then RESUME.
- **A GPS turtle says no GPS underground**: normal with basic-modem hosts; it works blind down there.

---

## For developers

- Layout: `miner/` (turtle: `miner.lua` main loop, `nav.lua` movement and recovery, `state.lua` journal and saves, `inv.lua` fuel and storage, `mine.lua` grid and veins, `net.lua` comms, `config.lua` settings, `install.lua`, `updater.lua`, `startup.lua`), `servers/` (monitor, update server, relay), `setup.lua`, `test/` (simulator), `docs/`.
- Tests: `lua5.4 test/run.lua` runs every scenario in a simulated CC world (modem ranges, GPS, chunks, crashes, world rollback). `lua5.4 test/run.lua 37` runs one.
- Design and progress: `docs/PLAN.md`, `docs/INTERFACES.md`, `docs/PROTOCOL.md`, `docs/COMMS.md`, `docs/CLUSTER_GPS_PLAN.md`, `docs/ARMY_PLAN.md`, and `docs/TRACKING.md` (what's done, open items, the in-game checklist).
- Every file starts with `-- Version: x.y.z`; bump it when you change the file or the updater won't ship it.
- `farmer/` is a separate older program, not covered here.
