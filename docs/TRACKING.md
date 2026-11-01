# TurtleMiner Fix Tracker

Design: [PLAN.md](PLAN.md). This file is the single source of truth for progress. Update it at the end of every work session and after every agent returns.

Status key: `TODO` · `DOING` · `BLOCKED` · `REVIEW` · `DONE`

## Decisions

| ID | Question | Answer | Status |
|----|----------|--------|--------|
| D1 | Rewrite vs patch | Rewrite | DONE |
| D2 | GPS | With and without, per turtle at runtime | DONE |
| D3 | Old copies | Delete (farmer/ stays) | DONE |
| D4 | Monitor | Touchscreen + pocket computer layout | DONE |
| D5 | Old protocol compatibility | None | DONE |
| D6 | Fuel chest | Auto-detect any setup | DONE |

## Work packages

| WP | Owner | Status | Branch / worktree | Commit | Notes |
|----|-------|--------|-------------------|--------|-------|
| WP-0 Contracts (PROTOCOL.md, INTERFACES.md, config skeleton) | coordinator | DONE | claude/vigilant-pasteur-g2krss | see log | config.lua written by coordinator; WP-C owns it from here |
| WP-T Simulator + scenarios | agent 1 | DONE | merged | 88599b0, a427369 (cherry-picked) | `lua5.4 test/run.lua`, ~4 s. Selftest 50 checks. Coordinator fixed harness to set HOME_Y for no-GPS turtles. |
| WP-A State + Nav | agent 2 | DONE | merged | 52fd13c (cherry-picked) | 63 throwaway checks pass. Additions: nav.init opts.cfg/onEvent, nav self-snapshots every SNAPSHOT_EVERY, st.lost/st.facingUnknown, S journal line has 7th field. Turn crash without GPS → NEEDS_HELP (inspect heuristic from PLAN not built). Unlimited fuel without GPS can't detect rollback. |
| WP-B Inv + Mine | agent 3 | DONE | merged | 0f9637d (cherry-picked) | 67 throwaway checks pass. Additions: st.job.geom (grid frozen per job), mine.retreat(), vein returns count,signal,reason, ctl.event optional, c:ores/forge:ores tags count as ore. |
| WP-C Net + Main | agent 4 | DONE | merged | 2ff1bd3 (cherry-picked) | 42 stub-harness checks pass; not yet run with real nav/mine. Accepted deviations: RESET_HOME while lost sets pos=home (keeps job); GPS first boot prefers server home record; net.setValidator added; st.flags.afterHome; SET string values coerced. |
| WP-D Monitor | agent 5 | DONE | merged | e2cbc83 (cherry-picked) | 69 throwaway checks pass incl. render fuzz 1x1..164x81. central_monitor.lua ~1085 lines (over guideline, accepted). Protocol gaps fixed by coordinator: fleet id, ack forwarding fields, home_get prefers found=true, FOCUS values documented. |
| WP-E Install / Update / Cleanup | agent 6 | DONE | merged | 88aa268 (cherry-picked) | 37 throwaway tests pass. Deviations: updater called via require().run not shell.run; seq starts random; all-or-nothing updates; installer asks label/Y/focus/corridors (storage auto-detected) |
| WP-I Integration | coordinator | DONE | claude/vigilant-pasteur-g2krss | | All 20 scenarios + selftest pass (21/21). Fix commits: 8d83b90 coal/lists, e7951b3 recovery/mob, 0a88a2f fuel-to-leave. |
| WP-R Code review | agent 7 | DONE | read-only | | 21 findings (2 high). #2 and #13 fixed by coordinator; rest in WP-F below. |
| WP-F Review fixes | agents X/Y/Z | DONE | worktrees | | X: nav/state (#1,#4,#5,#10). Y: inv/mine/sim (#1 scan,#3,#4,#6,#10,#11,#20). Z: miner/monitor/install/README (#7,#8,#9,#12,#14-#19,#21) |
| WP-G In-game acceptance | you | TODO | | | |

## Comms (see COMMS.md)

| WP | Status | Notes |
|----|--------|-------|
| CM-1 GPS-mode turtles recover blind underground; no repeated GPS timeouts | DONE | a4acfb4, scenario 40 |
| CM-2 Store-and-forward commands on server | DONE | queued per turtle, sent when heard, retried until acked, 24 h expiry / replaced by same kind; pocket path too. Scenario 41 |
| CM-3 `away` + ETA, overdue-only alerts | DONE | ETA from job size + measured trips (st.stats) + fuel; AWAY "back by ~hh:mm", OVERDUE at 50% + 2 min. Scenario 42 |
| CM-4 Catch-up event log | DONE | max 50, coalesced, `catchup` on contact, merged by original time; event ids dedupe. Scenario 43 |
| CM-5 Bridge: ender nodes always relay, turtle distance relay, `relay` program | DONE | modem kind detected, `hop` in every message, contact = heard in 30 s; mesh across wired/wireless/ender on every computer; `setup relay`. Scenarios 44-46 |

## Cluster + GPS (see CLUSTER_GPS_PLAN.md)

| WP | Status | Notes |
|----|--------|-------|
| CG-0 Protocol | DONE | PROTOCOL.md "Cluster": cluster_hello / cluster_leader / cluster_delta (epoch + dseq) / cluster_snap_req / cluster_snapshot / cluster_fwd (cmd, merge); leader-only home_get + queue; leader fleet relayed |
| CG-1 tminer_server + split central_monitor | DONE | one program, roles per PC at boot + every 60 s (ui/gateway/link/update/gps hook), loops via parallel; modules tm_db 597, tm_radio 344, tm_cluster ~370, tm_ui 524, tm_views 301, tm_update 136 lines; central_monitor.lua = 26-line launcher (same API); setup server/monitor/pocket install it; github_pull installs modules with the launcher (all-or-nothing). Scenario 49 (keyboard-only basic PC + basic monitor) |
| CG-2 Cluster leader/replica/failover | DONE | servers/tm_cluster.lua: join 3 s, election newest (epoch, dseq) then lowest ID, no preemption, deltas at once/5 s, failover after 15 s + 2 s (measured 15.3 s), forwarded UI commands resent until replicated, split-heal merge. Scenarios 47, 48, 50 |
| CG-3 GPS offer + silent auto-measure + fallback + drift | TODO | offer only when valid (else quiet); monitor + PC terminals; one confirm; anchors: PC GPS fix / GPS turtles; fallback asks on PC terminal |
| CG-3b Turtle distance samples | TODO | |
| CG-4 Monitor cluster + GPS pages | TODO | |
| CG-T Simulator wired/cluster/GPS geometry | DOING | done: multi-PC clusters, basic/advanced computers (no colour/mouse/multishell), monitor peripherals (basic: no touch), key/char/touch/click input. GPS geometry left for CG-3 |

## Network + mesh updates (see MESH_UPDATE_PLAN.md)

| WP | Status | Notes |
|----|--------|-------|
| MU-0 Mining network join + signed messages | TODO | Closes today's multiplayer hole (anyone can command turtles / pose as update server). First after cluster |
| MU-1 Mesh updates (summaries, signed releases, chunked transfer, manual-edit detection) | TODO | |
| MU-2 Probation + rollback + bad marks | TODO | |
| MU-3 Check now button + updater --pull | TODO | |

## Army (phase 2, see ARMY_PLAN.md)

| WP | Status | Notes |
|----|--------|-------|
| AR-0 Protocol + interfaces | TODO | Questions answered. Blocked on: WP-F done + in-game test |
| AR-1 Coordinator | TODO | |
| AR-2 Turtle group mode | TODO | |
| AR-3 Bridge (turtle relay + relay program) | TODO | Auto relay on every turtle, distance-to-server based |
| AR-4 Underground GPS nodes | TODO | |
| AR-5 Monitor group view | TODO | |
| AR-T Simulator multi-turtle | TODO | |
| AR-R Review + in-game | TODO | |

## Root causes

| # | Short | WP | Status | Verified by |
|---|-------|----|--------|-------------|
| R1 | Facing not saved on turns | A | DONE (unit) | scenario 2 |
| R2 | Save after move, not before | A | DONE (unit) | scenario 2 |
| R3 | Non-atomic save, corrupt → assumes home | A | DONE (unit) | scenario 2 |
| R4 | GPS facing probe guesses north | A | DONE (unit) | scenario 2 (GPS) |
| R5 | Blocking prompts after reboot | B, C | DONE (unit) | scenario 1, 6 |
| R6 | Command listener killed after 1s | C | DONE (unit) | scenario 7 |
| R7 | Branch listener string vs table | B | DONE (unit) | scenario 7 |
| R8 | REQUEST_STATUS crash | C | DONE (unit) | scenario 7 |
| R9 | Commands not addressed to one turtle | D | DONE (unit) | scenario 7 |
| R10 | Two coroutines moving the turtle | C | DONE (unit) | scenario 7 |
| R11 | Fuel: no refuel, coal dumped, threshold unused | B | DONE (unit) | scenario 5 |
| R12 | New corridor overlaps old | B | DONE (unit) | scenario 8 |
| R13 | returnHome failure ignored | B, C | DONE (unit) | scenario 4 |
| R14 | Gives up after 10 tries | A | DONE (unit) | scenario 3 |
| R15 | Per-block network + disk spam | C, D | DONE (unit) | review |
| R16 | Updater misbehaves | E | DONE | WP-E tests; in-game pending |
| R17 | Duplicate old copies | E | DONE | WP-E tests; in-game pending |

## Review findings (WP-R, 2026-10-31)

| # | Sev | Finding | Owner | Status |
|---|-----|---------|-------|--------|
| 1 | HIGH | Crash during a turn strands turtle (no GPS always; GPS calibrate can't turn/dig in 1x1 tunnel) | X + Y + blind | DONE (X GPS calibrate + inspect; Y fewer turns 274→224; blind: no-GPS/no-fix probe against the known-open map + home chest, sweep 26/448 → 442/448; residual: turns of the very first home scan, symmetric caves → NEEDS_HELP) |
| 2 | HIGH | `wget run install` can't require its modules; fallback startup never auto-updates | coordinator | DONE (package.path, updater replaces fallback startup, README uses wget + install) |
| 3 | HIGH/MED | Chest on modem side invisible → loot into fuel chest / fuel chest unused | Y | DONE (Y) |
| 4 | MED | Crash between refuel and journal R line → position unknown at home | X + Y | DONE (X+Y, scenario 26: 18 crash cases recover) |
| 5 | MED | Unlimited fuel + no GPS → every dangling move intent = NEEDS_HELP | X + blind | PARTIAL (blind: air→air settled when the known-open map tells P and P+dir apart, e.g. moved into fresh rock; walking back through own tunnel still NEEDS_HELP) |
| 6 | MED | FUEL_KEEP reserve never burned even when stranded | Y | DONE (Y + miner wiring) |
| 7 | MED | DONE can't be left by raising MAX_CORRIDORS; no RESET_JOB button | Z | DONE (Z) |
| 8 | MED | Monitor/pocket can only SET TARGET_Y and FOCUS | Z | DONE (Z, SET screen all 16 keys) |
| 9 | MED | Lost state + GPS → walks back to old server home record | Z | DONE (Z, home_clear added to protocol) |
| 10 | MED | goHome/backtrack dig anything incl. chests; climb-first fallback near base | X + Y | DONE (X+Y; goHome stops on protected block in retreat) |
| 11 | MED/LOW | Fuel-home uses Manhattan, real route via tunnels is longer | Y | DONE (Y routeHomeLength) |
| 12 | LOW/MED | UPDATE parks turtle in IDLE until RESUME | Z | DONE (Z) |
| 13 | LOW | Installer GPS check always false | coordinator | DONE |
| 14 | LOW | Defaults reach beyond loaded chunks; nearby homes overlap (docs) | Z | DONE (README) |
| 15 | LOW | "stuck" → NEEDS_HELP without auto retry | Z | DONE (Z, 5 retries) |
| 16 | LOW | Attacks players in its path (docs/limit) | Z | DONE (README) |
| 17 | LOW | PAUSED turtle goes home after reboot | Z | DONE (Z) |
| 18 | LOW | miner.lua VERSION constant stale | Z | DONE (Z) |
| 19 | LOW | startup may run updater mid-job when last journal line is R | Z | DONE (Z) |
| 20 | LOW | Any inventory peripheral (furnace etc.) may be picked as dump | Y | DONE (Y) |
| 21 | LOW | SET HOME_Y shifts pos but not journal history | Z | DONE (Z, HOME_Y only at home, journal wiped) |

## Test scenarios (simulator)

| # | Scenario | Status | Last result |
|---|----------|--------|-------------|
| 1 | Fresh start, 2 corridors, unload, no prompts | DONE | PASS |
| 2 | Crash after each op type, reboot, position + facing correct (GPS / no GPS) | DONE | PASS (boot no longer saves stale snapshot before recover) |
| 3 | 20-high gravel column not treated as stuck | DONE | PASS |
| 4 | Bedrock → NEEDS_HELP, no loop | DONE | PASS |
| 5 | Low fuel → return, refuel, continue, never strands | DONE | PASS (surplus fuel → fuel chest; single chest still gets surplus beyond FUEL_TARGET) |
| 6 | Chest full → NEEDS_HELP, resumes when emptied | DONE | PASS |
| 7 | Commands addressed correctly; RETURN_HOME mid-vein | DONE | PASS |
| 8 | Corridors never overlap | DONE | PASS (r=0,11,22) |
| 9 | World rollback after crash (state ahead of world by N moves) recovered via fuel journal | DONE | PASS (same root cause as 2) |
| 10 | Pocket layout renders in 26x20 without overflow | DONE | PASS |
| 11 | Deepslate transition: stone/deepslate variants one vein, cobbled_deepslate is trash | DONE | PASS |
| 12 | Jagged bedrock (-64..-60): downward vein stops at bedrock, run continues | DONE | PASS |
| 13 | Caves and ravines crossed: no stuck, wall ores found, position exact | DONE | PASS |
| 14 | Lava aquifers below Y -55 and water aquifers: fluids passed, not stuck | DONE | PASS |
| 15 | Amethyst geodes + falling pointed dripstone: no stuck, not ore, trash list gaps reported | DONE | PASS (trash list extended) |
| 16 | Raw ore drops fill inventory mid-vein: backtrack, unload, resume at right step | DONE | PASS |
| 17 | Large iron/copper ore veins: raw_*_block is ore, VEIN_MAX stops cleanly, filler is trash | DONE | PASS (raw_*_block = ore, family 'iron' etc.) |
| 18 | 1.18 ore heights: FOCUS diamond at -58; SET TARGET_Y 16 + iron mid-job | DONE | PASS |
| 19 | Cliffs: home at Y 150, 208-block shaft, exact fuel, never strands; negative HOME_Y | DONE | PASS (reported need now includes fuel boot spends on GPS calibration) |
| 20 | Cave mobs (leave vs never leave → timeout NEEDS_HELP) and buried ore found | DONE | PASS (attacks no longer reset stuck timer) |
| 36 | Blind turn crash in a 1x1 tunnel settled by probing (incl. crashes mid-probe); symmetric cave → NEEDS_HELP; unlimited-fuel moves | DONE | PASS |
| 37 | Crash on every turn of a standard no-GPS run (reviewer repro) | DONE | PASS (218/224; 2 corridors 442/448, before 26/448) |
| 38 | SURFACE_IF_LOST: climbs to 8 open cells, off = stays, fuel floor 50, chest above kept | DONE | PASS |
| 39 | Offline boot: no waits (first op at 0 s); 39x13 status block | DONE | PASS |
| 40 | GPS only above Y 0: turn crash at depth recovers blind; no repeated locate waits; lost + SURFACE_IF_LOST gets a fix and goes home | DONE | PASS |
| 47 | Cluster: 1 wireless + 2 wired-only PCs act as one server (one leader, one home reply, keyboard cmd from wired-only PC applied once) | DONE | PASS |
| 48 | Leader switched off: replica takes over (15.3 s), queued cmds + homes kept, outage cmd delivered once, old leader rejoins as replica | DONE | PASS |
| 49 | Keyboard-only UI on a basic PC + basic monitor: every screen, bounds + greyscale checked | DONE | PASS |
| 50 | Two wired networks bridged by one wireless PC: split leaders merge into one, queued cmd handed over | DONE | PASS |

## In-game acceptance (you)

- [ ] `install` on a fresh turtle finishes with no code edits
- [ ] Turtle mines, unloads, goes back to where it was
- [ ] `/stop` or leave the chunk mid-tunnel, come back: turtle resumes on its own, right spot, right facing
- [ ] Kill the server process (not /stop) mid-tunnel, restart: turtle recovers position
- [ ] Mine at Y -58 near lava lakes: turtle passes lava without getting stuck (watch the monitor)
- [ ] Home on a mountain (Y > 100): turtle gets down and back with fuel to spare
- [ ] Pocket computer shows the fleet and can send commands
- [ ] RETURN_HOME from the monitor affects only the chosen turtle
- [ ] Fill the chest: monitor shows NEEDS_HELP with the reason; empty it: turtle carries on
- [ ] Run it until fuel gets low: it comes home, refuels, continues
- [ ] Unplug the monitor server for a while: turtles keep mining; it catches up when back
- [ ] Push an update from the update server: turtles take it at home, one reboot

## Log

| Date | Who | What |
|------|-----|------|
| 2026-10-31 | coordinator | Review done, PLAN.md + TRACKING.md written. Waiting on decisions D1–D6 before WP-0. |
| 2026-10-31 | coordinator | Decisions D1–D6 answered. Plan updated (journal recovery, grid, pocket monitor). Starting WP-0. |
| 2026-10-31 | coordinator | WP-0 done: PROTOCOL.md, INTERFACES.md, miner/config.lua. Launched agents for WP-T, A, B, C, D, E in parallel worktrees. |
| 2026-10-31 | coordinator | WP-E merged. Told WP-A to keep .tm_state/journal format WP-E reads; told WP-C to use require("updater").run and random seq start. |
| 2026-10-31 | coordinator | WP-A merged. Sent WP-C the nav additions (onEvent, st.lost cleared by RESET_HOME, nav self-snapshots). |
| 2026-10-31 | coordinator | WP-C merged. Deviations accepted (RESET_HOME while lost = 'turtle is at home now'). |
| 2026-10-31 | coordinator | WP-B merged. Integration fixes from WP-B's notes: retreat before goTo home, no-GPS turtles used home Y=0 while TARGET_Y is world Y (added HOME_Y), chest-below-home conflict documented + installer warning. |
| 2026-10-31 | coordinator | WP-D merged. net.request now prefers found=true home replies across servers; PROTOCOL.md updated with WP-D's gaps. Only WP-T outstanding. |
| 2026-10-31 | coordinator | Scenarios doubled to 20 with 1.18+ Caves & Cliffs cases (deepslate, jagged bedrock, caves, lava/water aquifers, geodes, dripstone, raw ore drops, large ore veins, ore heights, tall terrain, cave mobs). Sent to WP-T. |
| 2026-10-31 | coordinator | First full run with all real modules: 16/21 pass (incl. selftest). Failing: 2, 5, 9, 19, 20. Launching fix agents. |
| 2026-10-31 | coordinator | Fix agents (2/9/20 recovery+mob, 5/15/17 coal+lists, 19 fuel) hit the usage limit before committing anything; resumed. |
| 2026-10-31 | coordinator | Coal/lists fix merged (8d83b90): 17/21 pass. Remaining: 2, 9, 19, 20. |
| 2026-10-31 | coordinator | Recovery/mob fix merged (e7951b3). Root cause of 2/9: setPhase('RECOVER') saved a stale snapshot over the journal before nav.recover ran. |
| 2026-10-31 | coordinator | Fuel-to-leave fix merged (0a88a2f). Suite 21/21 green. miner.lua bumped to 1.1.2 (two fixes both used 1.1.1). Starting WP-R review. |
| 2026-10-31 | coordinator | Added setup.lua (one-command download per computer from this branch); README install points at the branch. User starting in-game setup while WP-R review runs. |
| 2026-10-31 | coordinator | User install: 'still missing config.lua, state.lua'. Review #2 (require path under wget run) is the likely cause; fixed + README now uses `wget ... install.lua` then `install`. Launching WP-F fix agents X/Y/Z. |
| 2026-10-31 | coordinator | WP-F X merged (7cd8432): 25/25 green. Residual: no-GPS turn crash in solid face still needs RESET_HOME; GPS covers it. |
| 2026-10-31 | coordinator | Army scope answered; docs/ARMY_PLAN.md written. 4 open questions. Starts after WP-F + in-game test. |
| 2026-10-31 | coordinator | Army questions answered: 2nd shaft allowed, server near or far, GPS hardware ready, carry no-GPS turtles to join, auto bridge on all turtles. |
| 2026-10-31 | coordinator | WP-F Z merged (3d58acd): 30/30 green. Waiting on WP-F Y (inv/mine/sim). |
| 2026-10-31 | coordinator | WP-F Y merged (7e717a2); goHome now honours mine.retreat result (no digging fallback past protected blocks). Suite 35/35. Ready for in-game test. |
| 2026-10-31 | coordinator | Update server auto-pulls newer files from GitHub at boot + every 60 min (github_pull.lua), self-updates server programs with one guarded reboot. Tested with fake http/fs. Needs one manual `setup.lua server` re-run to install. |
| 2026-11-01 | coordinator | Offline use: keyboard controls on the turtle (R/P/B/S/H) so no monitor is needed for RESUME/RESET_HOME. Scenario 35 (no modem, keys) added. Suite 36/36. |
| 2026-11-01 | coordinator | Modem research (CC:Tweaked source): basic 64 blocks below Y 96, max(sender,receiver), ender = delivered if either end is ender. docs/COMMS.md written; CM-1..CM-5 planned; army plan updated for out-of-range reservations. |
| 2026-11-01 | coordinator | Clarified: general-purpose tool, no assumed setup. COMMS.md rule 0: everything detected at runtime, settings only override. |
| 2026-11-01 | blind agent | Blind turtle: turn crashes without a GPS fix settled by probing the 4 neighbours against the known-open map (journal cells, finished grid cells, home chest; shaft → climb home). Reviewer sweep 26/448 → 442/448. Unlimited-fuel moves settled when the map tells them apart. GPS turtles out of range fall back to blind recovery, failed locates cached. SURFACE_IF_LOST. No network work offline. 39x13 status screen. Scenarios 36-40. Suite 41/41. |
| 2026-11-01 | coordinator | Blind-turtle work merged (a4acfb4): no-GPS turn-crash recovery 26/448 → 442/448, SURFACE_IF_LOST, status screen. Suite 41/41. Starting CM-2..CM-5. |
| 2026-11-01 | coordinator | Cluster + GPS phase planned (CLUSTER_GPS_PLAN.md). Source check: gps host needs a wireless modem, wired can't serve GPS, 3 hosts = ambiguous fix → need >= 4 wireless hosts. |
| 2026-11-01 | coordinator | GPS setup decisions: offered not required; quiet unless >= 4 valid hosts; offer on monitor + PC terminals; one confirm; silent auto-measure (raw modem distances + anchors), fallback asks coords on the PC's own terminal; drift auto-fix or pause host. |
| 2026-11-01 | coordinator | Requirement: basic + advanced hardware everywhere (keyboard-first UI, greyscale, no multishell) and full mesh relaying across wired/wireless/ender. Added to COMMS.md + cluster plan; sent to comms agent. |
| 2026-11-01 | comms agent | CM-2..CM-5: simulator models modem range (basic 64 below Y 96, max(sender,receiver), ender always, wired per network, GPS same rule). Store-and-forward commands, `away`/ETA + overdue-only alerts, catch-up log, hop distances + relay rules (ender always, basic only closer, random delay + suppression), `relay` program, mesh over wired/wireless, keyboard navigation for basic computers. Storm test: 10 basic turtles, 2.13 transmissions per message (flooding: 11.6). Scenarios 41-46. Suite 47/47. |
| 2026-11-01 | coordinator | Comms merged (5788e0c). Suite 47/47. Next: Cluster + GPS (CG-0..CG-4). |
| 2026-11-01 | coordinator | User hit 'attempt to index local f (nil)' in setup.lua: fs.open unchecked. Now: moves a file blocking a needed folder aside, reports folder/read-only/disk-full with free space, writes via .tmp. |
| 2026-11-01 | coordinator | README rewritten as a full user guide (install per role, using it, networking, GPS, clustering marked coming, updates, settings, help messages, troubleshooting, dev notes). |
| 2026-11-01 | coordinator | User report: turtle frozen to commands after RETURN_HOME. Not reproduced on current code (scenario 51: IDLE acks STATUS/SET/PAUSE/RETURN_HOME/UPDATE, RESUME works twice). Asked user for version + what the card shows. |
| 2026-11-01 | coordinator | User: monitor RESUME showed ok but IDLE turtle didn't move; key R worked. Not reproduced (scenario 51). Turtle now prints every received command on its screen (miner 1.4.1) to tell 'not delivered' from 'delivered but ignored'. Open: get version + screen trace next time. |
| 2026-11-01 | coordinator | Mesh updates planned (MESH_UPDATE_PLAN.md): multiplayer assumed, network join required at install, every message signed (HMAC-SHA256), devices apply + reboot once, hourly + Check now, auto rollback with bad marks. Starts after cluster; MU-0 first. |
| 2026-11-01 | cluster agent | CG-0..CG-2: tminer_server (one program, roles detected), central_monitor split into tm_db/tm_radio/tm_cluster/tm_ui/tm_views/tm_update (launcher kept), cluster leader/replica/failover over any modem mix, keyboard-driven basic monitors, setup + github_pull updated. Scenarios 47-50. Suite 51/51. GPS hook: optional tm_gps.lua setting T.gps = {wanted(), loop()}. |
| 2026-11-01 | coordinator | Cluster merged (f1aed0f); setup.lua conflict resolved (keeps safe writes). README updated for tminer_server. |
