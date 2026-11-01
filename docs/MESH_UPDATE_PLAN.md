# Mining Network + Mesh Updates Plan

Tracked in [TRACKING.md](TRACKING.md) under "Network + mesh updates". Decisions (2026-11-01): assume multiplayer, joining a network is required at install, devices apply updates and reboot once, GitHub hourly check stays plus a "Check now" button, automatic rollback of bad updates.

## 1. Mining network (required)

Every device belongs to exactly one **mining network**: a name plus a secret key. Without it, anyone on a multiplayer server with a modem could command your turtles, fake their status, or push code to them.

- **Joining at install:** `install` (turtles) and `setup.lua` (computers, pockets) ask: *create a new network* or *join an existing one*.
  - **Create:** the device picks a random **join phrase of 4 words** from a fixed 1024-word list (about 40 bits, e.g. `lava oak ember pick`) and shows it. The key is derived from the phrase and the optional network name (deliberately slowed, so each guess is expensive). CC terminals have no copy-paste, so it's built to be typed: any case or spacing works, and an unknown word gets a "did you mean" suggestion.
  - **Join by typing** the 4 words.
  - **Join without typing:** put a floppy disk in a drive next to any network device and choose "copy network to disk", then put it next to the new device; or have the new device ask to join and press **Approve** on the monitor within 2 minutes. Approve sends the key over the air, so it's only safe if nobody else is listening at that moment; the disk and the phrase are safe.
  - The device checks the phrase by hearing a signed message from the network (or accepts it offline and checks later).
  - Stored in `.tm_network` (not in `settings`, so `set` listings don't show it). `setup.lua network` changes it later; the monitor can show the join code on demand.
- **Every `TMINER` message is signed:** HMAC-SHA256 with the network key, covering everything except the fields relays change (`hops`, `hop`, `via`, `mk`). Pure-Lua SHA-256 (no CC built-in).
  - Messages with a missing or wrong signature are dropped and never relayed. Several players' networks can share the airwaves without seeing each other.
  - Replay protection: the existing `from:boot:seq` dedupe plus a timestamp window (messages more than 10 minutes old are dropped, except catch-up logs, which carry their own signed timestamps).
  - Cost: status messages are small (a few ms of hashing). Relays don't re-sign.
- **GPS hosts can't be secured** this way (CC's GPS protocol is fixed). The constellation check from CLUSTER_GPS_PLAN.md still catches hosts whose distances don't match, and turtles reject a fix that disagrees with their journal by more than a few blocks.

## 2. Mesh updates

- **What each device needs:** a role file set: miner (turtles), server (cluster PCs, plus the miner set in `/files/` for serving), monitor/pocket, relay, gps. A device only installs files from its own set, but can pass on anything it holds.
- **Advertising:** every device adds a short summary to messages it already sends: a hash of its installed file versions per role set. When a peer's summary differs it asks for the version list (`files_list`), then fetches the files that are newer (`file_get`) from that peer over the mesh. Large files go in chunks (16 KB) so they relay safely.
- **Signed releases:** a device only installs a file that comes with a release note (file name, version, SHA-256 of the content) signed with the network key. Whoever introduces a new version signs it:
  - the GitHub pull on a server, or
  - a manual edit: a device that finds one of its own files with a higher `-- Version:` than its last release (checked at boot and every 10 minutes) signs and announces it.
- **Applying:**
  - Turtles: only at home, between trips (as now). Reboot at most once per update.
  - Computers and pockets: when idle (no user input for 30 s, no pending command handling), then one reboot.
  - All-or-nothing per device: stage `.new` files, check each with `load()` and its hash, swap, keep `.bak`.
- **Spreading:** each device that updates becomes a source for its neighbours, so a new version reaches everything in range within minutes, and devices out of range catch up when they're next heard. A device fetches from at most one peer at a time, to keep traffic down.
- **GitHub:** the hourly check stays as a backup on any device with HTTP and the update role. A **Check now** button on the monitor (and `updater --pull` on a computer) asks the leader, or any device with HTTP, to pull from GitHub at once; the result spreads by mesh.

## 3. Rollback

- After applying an update, a device runs on **probation** for 5 minutes (turtles: until their first successful trip).
- If it crashes, fails to start, or reboots more than twice in that window, it restores the `.bak` files, reboots into the old version, and marks the release **bad**.
- A bad mark (release id plus the reason, signed) spreads like an update. Devices that haven't applied it skip it. Devices that already applied it roll back too, and the monitor shows "update x.y.z rolled back on #12: <reason>".
- A newer release clears the bad mark (you fix the problem, bump the version, it spreads again).

## Work packages

| WP | What |
|----|------|
| MU-0 | Network join (install + setup + monitor "show join code"), `.tm_network`, pure-Lua SHA-256 + HMAC, signing and checking on every message, replay window. Simulator: a foreign player's devices on the same airwaves, wrong key, replayed and forged messages |
| MU-1 | Role file sets, version summaries in messages, `files_list` / chunked `file_get`, signed release notes, manual-edit detection, apply rules per device kind |
| MU-2 | Probation + rollback, signed bad marks, monitor display |
| MU-3 | "Check now" button + `updater --pull`; GitHub hourly backup moved into the update role |
| MU-T | Scenarios: one PC pulls → all devices update; manual edit spreads; a broken file never installs; a release that crashes rolls back everywhere; a device out of range catches up; foreign network ignored; forged update rejected |

Order: after the cluster work (same server files). MU-0 first: it closes the multiplayer hole that exists today (anyone can command turtles or answer as an update server).
