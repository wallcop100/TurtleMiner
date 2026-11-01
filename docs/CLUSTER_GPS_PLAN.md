# Server Cluster + GPS Constellation Plan (next phase)

Tracked in [TRACKING.md](TRACKING.md) under "Cluster + GPS". Builds on the comms work (COMMS.md). General-purpose: every PC detects its own hardware and role; no settings required.

## Hard facts (CC:Tweaked source, `rom/programs/gps.lua`, `rom/apis/gps.lua`)

- `gps host` only uses a **wireless** modem ("No wireless modems found. 1 required."). It only answers pings that carry a distance, and wired messages carry none, so **wired modems can't serve GPS**.
- `gps.locate` takes fixes from 3 hosts and uses a 4th to choose between the two mirror solutions. **With only 3 hosts the answer is ambiguous and `locate` returns nil** (unless the turtle happens to be in the hosts' plane). Hosts that are nearly in a line make it fail outright.
- The fix uses the host's **true** position (the distance is measured by the game), so each host must announce its exact block coordinates. A typo means wrong positions for every turtle.
- Range: COMMS.md (64 blocks below Y 96 for basic modems, more when high up; an ender modem at either end means always delivered).

**Consequence for "3 PCs, 1 wireless + 2 wired":** that gives 1 GPS host, so no GPS fixes. It works fine as a server cluster. For GPS each host PC needs its own wireless modem (a PC can carry wired and wireless at once), and there must be at least 4 of them, not all at one height. The tool detects this and says exactly what's missing.

## What gets built

### 1. One server program, roles detected per PC

`tminer_server` replaces running `central_monitor` / `update_server` / `relay` separately. Same program on every server PC; each PC works out its roles at boot and re-checks every minute:

| Detected | Role |
|----------|------|
| Monitor attached (or it's a pocket) | UI |
| Wireless or ender modem | Radio gateway (talks to turtles, relays per COMMS.md) |
| Wireless modem + GPS coordinates set | GPS host (runs the host loop alongside everything else) |
| Wired modem | Cluster link to the other server PCs |
| `/files/` present | Update server (+ GitHub pull) |
| Nothing special | Cluster member (replica) |

### 2. Cluster over wired (or wireless) links

- Server PCs find each other with a `cluster_hello` on every modem. A wired-only PC works through any gateway in the cluster.
- **Leader** = lowest computer ID currently seen. The leader owns the database (homes, queued commands, away/ETAs, event log, later army claims) and sends a snapshot plus changes to the others every 5 s.
- Leader gone for 15 s → next lowest ID takes over from its replica. The old leader rejoins as a replica (newest snapshot wins by sequence number).
- Any PC can show the UI; commands from any UI go to the leader.
- Only the leader answers turtles' `home_get`, so turtles never get conflicting answers.

### 3. GPS setup (`setup.lua gps`, or the "GPS" page on the monitor)

- **Coordinates for this PC:** if a working GPS already gives a fix here, it offers that. Otherwise it asks you to type X Y Z from F3, looking at the **computer block**. It asks twice and compares, to catch typos.
- **Constellation check across the cluster:** every host shares its coordinates. The leader checks:
  - count ≥ 4 hosts with wireless modems (shows "3 of 4: add one more host")
  - not all in one plane (tetrahedron volume above a minimum; the usual mistake is all hosts at the same Y)
  - spread: hosts at least 6 blocks apart in each direction
  - duplicate or impossible coordinates
- **Coverage report:** from host heights and modem kinds (basic/ender), it estimates the GPS reach: "turtles get GPS down to about Y 20 within 100 blocks; nothing at Y -58". With ender modems: "everywhere in this dimension".
- **Live self-test:** hosts with a wireless modem ping each other and compare measured distances with the configured coordinates. Any host whose numbers don't add up is flagged ("host #7: coordinates off by ~3 blocks, re-enter").
- The monitor shows "GPS: 4 hosts OK, reach to Y 20" or what's wrong.

### 4. Turtles

Nothing to configure. They already treat GPS as "available here now or not" (blind fallback). They report each fix and failed locate with position, so the monitor builds a coverage map over time ("GPS seen down to Y …").

## Work packages

| WP | What | Files |
|----|------|-------|
| CG-0 | Protocol: cluster_hello, snapshot/delta, leader, gps_host_info, gps_check | docs/PROTOCOL.md |
| CG-1 | `tminer_server`: role detection, run loops in parallel, setup.lua `server` installs it | `servers/tminer_server.lua`, split of `central_monitor.lua` into ui / db / radio modules |
| CG-2 | Cluster: discovery, leader election, replication, failover | `servers/cluster.lua` |
| CG-3 | GPS host role + setup wizard + constellation check + self-test + coverage | `servers/gpshost.lua`, `setup.lua` |
| CG-4 | Monitor: cluster page (members, leader, roles), GPS page | UI module |
| CG-T | Simulator: wired networks, multi-PC clusters, GPS geometry; scenarios below | `test/**` |

Scenarios: 3 PCs (1 wireless, 2 wired-only) act as one server and turtles stay in contact through the gateway; the leader is switched off and a replica takes over without losing queued commands; the GPS check rejects 1 host, 3 hosts, 4 coplanar hosts and a typo'd host, and accepts a good 4; a turtle gets correct fixes from a wizard-built constellation; coverage estimate matches the sim.

Order: after the comms work is merged (same files). Splitting `central_monitor.lua` (1200 lines) is part of CG-1.
