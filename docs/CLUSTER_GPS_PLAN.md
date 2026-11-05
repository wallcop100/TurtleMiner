# Server Cluster + GPS Constellation Plan

**Status 2026-11-05: CG-3, CG-3b, CG-4 built** (servers/tm_gps.lua, servers/tm_gpssolve.lua; scenarios 70-76). Measured point: the block a wireless modem is attached to (CC:Tweaked WirelessModemBlockEntity getPosition = modem pos relative to its facing), i.e. the computer block. Deviations: the mirror-image question is one extra number from a 4th PC; PCs added after setup join at the next set-up.

Tracked in [TRACKING.md](TRACKING.md) under "Cluster + GPS". Builds on the comms work (COMMS.md). General-purpose: every PC detects its own hardware and role; no settings required.

## Hard facts (CC:Tweaked source, `rom/programs/gps.lua`, `rom/apis/gps.lua`)

- `gps host` only uses a **wireless** modem ("No wireless modems found. 1 required."). It only answers pings that carry a distance, and wired messages carry none, so **wired modems can't serve GPS**.
- `gps.locate` takes fixes from 3 hosts and uses a 4th to choose between the two mirror solutions. **With only 3 hosts the answer is ambiguous and `locate` returns nil** (unless the turtle happens to be in the hosts' plane). Hosts that are nearly in a line make it fail outright.
- The fix uses the host's **true** position (the distance is measured by the game), so each host must announce its exact block coordinates. A typo means wrong positions for every turtle.
- Range: COMMS.md (64 blocks below Y 96 for basic modems, more when high up; an ender modem at either end means always delivered).

**Consequence for "3 PCs, 1 wireless + 2 wired":** that gives 1 GPS host, so no GPS fixes. It works fine as a server cluster. For GPS each host PC needs its own wireless modem (a PC can carry wired and wireless at once), and there must be at least 4 of them, not all at one height. The tool detects this and says exactly what's missing.

## Hardware and network rules

- Basic and advanced PCs, monitors and pocket computers are all supported (COMMS.md: keyboard for everything, greyscale fallback, no multishell).
- The cluster is a mesh: PCs relay between wired, wireless and ender modems, so any mix of wired networks and wireless hops forms one network. GPS hosting still needs a wireless or ender modem on the host itself.

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

### 3. GPS: offered, never required (decided 2026-11-01)

**When it offers.** The leader keeps a list of cluster PCs with a wireless or ender modem. It offers GPS only when there are at least 4 of them and their layout works (not all in one plane, at least 6 blocks apart; checked from measured distances, see below). Otherwise it **stays quiet**: no hints and no nagging. A PC added later re-triggers the check.

**Where.** A banner on the monitor and a prompt on each eligible PC's own terminal: `GPS possible with 4 PCs: [Set up] [Later] [Never]`. **One confirm for all:** accepting on any screen sets up every eligible PC and clears the prompt everywhere. "Never" is remembered cluster-wide until you turn it back on from the monitor's GPS page.

**Coordinates, automatic first, silent:**
1. **Measure the layout.** Each wireless PC pings the others on a raw modem channel. A `modem_message` event carries the true distance (rednet events don't, so this uses the modem API directly). Pairwise distances give the exact shape of the constellation, up to position, rotation and mirror image.
2. **Anchor it to world coordinates without asking**, using any one of:
   - a PC that already gets a GPS fix (another constellation, ender GPS),
   - turtles that know their world position (they had a GPS fix) passing within range: they record the measured distance to each PC as they move near home and send the samples to the leader,
   - a mix of these. The leader solves for the PC positions and accepts only when every measured distance agrees to within 0.5 block.
3. **Fallback: ask, only as much as needed.** If no anchor exists, the PCs whose coordinates would settle the layout (usually 3) show "Stand here, press F3, type this computer's X Y Z" on their **own terminal**. The monitor shows which PCs are still waiting. Each entry is checked against the measured distances at once ("doesn't match: distance to PC #4 should be 12.0, these coordinates give 15.3"), so typos are caught before anything goes live. The remaining PCs are worked out from the distances.
4. Implementation note: check in CC:Tweaked's source exactly which point a modem's distance is measured from (the computer or the attached modem block), and solve and announce that point, so every host's announced position matches what turtles measure.

**Hosting.** Once solved, every eligible PC runs the GPS host loop on its wireless or ender modem, alongside its other roles. The monitor's GPS page shows hosts, each one's state, and the coverage estimate (from host heights and modem kinds).

**Drift: fix or pause automatically.** Hosts re-measure each other every 10 minutes, and whenever a cluster member reboots or reappears. If a host's distances stop matching (PC moved or broken), the leader re-solves silently. If that isn't possible, that PC **stops hosting**, so it can't give wrong fixes, and the monitor shows why. If too few hosts remain, GPS stops cleanly (turtles fall back to blind mode) and the offer reappears when it can work again.

### 4. Turtles

Nothing to configure. They already treat GPS as "available here now or not" (blind fallback). They report each fix and failed locate with position, so the monitor builds a coverage map over time ("GPS seen down to Y …").

## Work packages

| WP | What | Files |
|----|------|-------|
| CG-0 | Protocol: cluster_hello, snapshot/delta, leader, gps_host_info, gps_check | docs/PROTOCOL.md |
| CG-1 | `tminer_server`: role detection, run loops in parallel, setup.lua `server` installs it | `servers/tminer_server.lua`, split of `central_monitor.lua` into ui / db / radio modules |
| CG-2 | Cluster: discovery, leader election, replication, failover | `servers/cluster.lua` |
| CG-3 | GPS: eligibility check, offer (monitor + PC terminals, one confirm), raw-modem distance measurement, solver (layout + anchors), minimal manual fallback with live typo check, host loop, drift fix/pause, coverage | `servers/gpshost.lua`, `servers/gpssolve.lua` |
| CG-3b | Turtles: record raw-modem distances to server PCs near home and send samples (anchor source) | `miner/net.lua` |
| CG-4 | Monitor: cluster page (members, leader, roles), GPS page | UI module |
| CG-T | Simulator: wired networks, multi-PC clusters, GPS geometry; scenarios below | `test/**` |

Scenarios: no offer with 3 wireless PCs or 4 in one plane; offer with 4 good ones, one confirm sets up all; silent setup when one PC has a GPS fix; silent setup from GPS-turtle samples; fallback asks only the needed PCs and rejects a typo; a moved host is paused, then re-solved; turtles get correct fixes from the result. Also: the whole UI driven by keyboard on a basic PC with a basic monitor (no touch, no colour); two wired networks bridged by one wireless PC form one cluster; 3 PCs (1 wireless, 2 wired-only) act as one server and turtles stay in contact through the gateway; the leader is switched off and a replica takes over without losing queued commands; the GPS check rejects 1 host, 3 hosts, 4 coplanar hosts and a typo'd host, and accepts a good 4; a turtle gets correct fixes from a wizard-built constellation; coverage estimate matches the sim.

Order: after the comms work is merged (same files). Splitting `central_monitor.lua` (1200 lines) is part of CG-1.
