# TurtleMiner: notes for Claude

CC:Tweaked branch-mining turtles plus server PCs (monitor UI, cluster, GPS, mesh updates, army mode). Big repo (~29k lines). **Don't explore broadly: use the map below, read only the files the task needs, and use `grep -n` / ranged reads on the large files.**

## Hard rules
- Target is CC:Tweaked Cobalt = **Lua 5.2 semantics**: no `//`, no bitwise ops, no `goto`, no `<const>`. `math.floor` all coordinates.
- First line of every file: `-- Version: x.y.z`. **Bump it on every change** or mesh updates won't ship the file. New files start at `1.0.0`.
- If you add/remove/rename a shipped file, update `M.SETS` in `miner/tmmesh.lua` **and** the copy in `setup.lua` (scenario 61 checks they match).
- Modules return a table, no globals. No `read()` outside `miner/install.lua`. Expected failures return `false, reason`, not `error()`.
- Don't change another module's API without updating `docs/INTERFACES.md` (the contract).
- `farmer/` is a separate legacy program. Ignore unless asked.

## Map (lines in brackets; [L] = large, grep before reading)
**miner/** (turtle, files flat in turtle root, loaded with `require`)
- `miner.lua` [1276 L]: main loop; worker coroutine (only code that moves) + `net.run`. State machine over `st.phase`.
- `nav.lua` [952 L]: journaled moves/turns, dig/attack retry, goTo, crash recovery, GPS sync, facing calibration.
- `mine.lua` [1067 L]: grid (shaft, spine, corridors, branches), vein following.
- `state.lua` [334]: atomic snapshot + append-only move journal. Owns `st`.
- `inv.lua` [475]: fuel/refuel reserve, trash, home chest detection, unload.
- `net.lua` [703]: rednet wrapper, TMINER protocol. Never moves the turtle.
- `config.lua` [115]: settings defaults (`tminer.<KEY>`).
- `group.lua` [339]: army mode, turtle side. `gpsmobile.lua` [61]: turtle acting as GPS host.
- `tmmesh.lua` [1181 L]: mesh updates for every device type; `M.SETS` file lists.
- `tmguard.lua` [248]: update journal/rollback, used by startup files. `updater.lua` [293]: CLI.
- `tmcrypto.lua` (SHA-256/HMAC, pure Lua), `tmjoin.lua` (create/join network), `tmwords.lua` (join-phrase words).
- `install.lua` [472]: the only interactive program. `startup.lua`: applies updates at home, starts miner.

**servers/** (one program, roles auto-detected; modules share table `T`)
- `tminer_server.lua`: entry, role detection. `startup.lua`: restart wrapper.
- `tm_db.lua`: state, turtle records, command queue, replication. `tm_radio.lua`: envelope, dedupe, relaying, turtle protocol.
- `tm_cluster.lua`: leader election between PCs. `tm_gps.lua` [874 L] + `tm_gpssolve.lua` (pure maths): GPS constellation.
- `tm_army.lua`: army coordinator (leader only). `tm_army_ui.lua` [809 L]: army pages.
- `tm_ui.lua`: drawing, input, turtle list. `tm_views.lua`: turtle card, commands, SET pickers, NET screen.
- `tm_update.lua`: GitHub pull origin. `relay.lua`: standalone relay. `central_monitor.lua`, `update_server/`: legacy launchers.

**setup.lua**: downloader per role (server/monitor/pocket/relay/turtle).

## Docs (big; read only the section you need, grep `^## ` first)
- `docs/INTERFACES.md`: module APIs, `st` table, shared types (Pos, Facing, Job, Phase). Read the relevant section before cross-module changes.
- `docs/PROTOCOL.md`: message kinds, signing, cluster/GPS/mesh messages.
- `docs/COMMS.md`: modem facts and relay rules. `docs/TRACKING.md`: progress source of truth (update it when finishing tracked work).
- `docs/PLAN.md`, `ARMY_PLAN.md`, `CLUSTER_GPS_PLAN.md`, `MESH_UPDATE_PLAN.md`: design history. Rarely needed.

## Tests
- Simulator in `test/sim/` (fake CC globals, voxel world, rednet, simulated clock). Helpers in `test/lib/harness.lua` [1170 L] and `test/lib/army.lua`.
- Scenarios in `test/scenarios/NN_name.lua`, numbered by area: 01-40 turtle core, 41-51 comms/cluster/UI, 52-55 crypto/network, 56-62 mesh updates, 70-76 GPS, 77-97 army/mobile GPS/misc.
- Run: `lua5.4 test/run.lua` (all), `lua5.4 test/run.lua 37` (one), `SIM_VERBOSE=1` for output. Run only the scenarios related to the change, then the full suite once at the end.
- `lua5.4` is not preinstalled in the cloud container: `apt-get install -y lua5.4` first.
