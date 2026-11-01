# TMINER Network Protocol v1

All traffic uses rednet protocol string `"TMINER"`. No other protocols. Messages are Lua tables.

## Envelope (every message)

| Field | Type | Notes |
|-------|------|-------|
| `v` | number | Always `1` |
| `kind` | string | See below |
| `from` | number | Original sender computer ID (not the relay) |
| `to` | number \| `"all"` \| `"server"` | Recipient. Turtles act only on `to == os.getComputerID()` or `"all"` |
| `boot` | number | `os.epoch("utc")` at sender boot. With `seq`, the dedupe key |
| `seq` | number | Increments per message from this sender since boot |
| `ts` | number | `os.epoch("utc")` when created |
| `hops` | number | 0 when sent; relays increment. Drop when `> 4` |
| `hop` | number or nil | Distance to the server of the node that **transmitted this copy** (relays overwrite it): server 0, others 1 + the smallest `hop` heard from a neighbour in the last 30 s, nil = unknown (out of contact) or the node never relays (pocket, `RELAY=off`) |
| `ohop` | number or nil | The origin's own distance to the server (never changed by relays). Used to relay towards a turtle |
| `via` | number or nil | Neighbour the transmitter's `hop` came from (split horizon: a node ignores adverts whose `via` is itself) |
| `mk` | string | Transmitter's modem kind: `"none"`, `"basic"`, `"ender"`, `"wired"` (relays overwrite it) |

Dedupe key: `from .. ":" .. boot .. ":" .. seq`. Receivers keep the last 256 keys and ignore repeats. Senders without `hop` that send server-only kinds (`fleet`, `cmd`, `home`, `update_manifest`, `file`) count as hop 0 (older servers).

## Contact

A node is **in contact** when it heard any message carrying a `hop` (a server, a relay, or a relaying turtle) in the last 30 s; its own hop is then known. The first 30 s after boot count as contact. A turtle out of contact skips `status` sends and buffers `event`s for a `catchup` (see COMMS.md); the newest status goes out as soon as contact returns. Events sent but not followed by any heard message before contact is lost are buffered again (the server dedupes by `eid`).

## Relay rules

Every node dedupes and never relays a copy with `hops >= 4`; relays send `hops + 1` and their own `hop`, `via`, `mk`, never changing `from`.

- **Servers and `relay` computers** (any non-turtle node running our software): relay every message they haven't seen, via `rednet.broadcast` (goes out on every open modem: wired, wireless, ender). A server relays `fleet` only when it comes from its cluster leader (so turtles near any gateway hear the one server). Skipped when the transmitter is an ender modem and the node has no wired modem (every wireless modem already heard it). This makes the network a mesh across modem types; wired links count as one hop like any other.
- **Turtles with an ender modem**: relay everything not sent by an ender modem.
- **Turtles with a basic modem** (`RELAY=auto`), only with a known hop, only when it moves the message closer:
  - towards the server (`to = "server"`, a server id, or an unknown id from a non-server): `myHop < sender hop` (or the sender's hop is unknown)
  - towards a turtle X (`to = X`, X's `ohop` known): `sender hop <= myHop < X's hop`
  - `to = "all"`: never
- `RELAY=on`: relay everything (flooding, still deduped). `RELAY=off`: never; `hop` not advertised.
- Turtles wait a random 0.05–0.35 s before relaying; a copy heard meanwhile from a node that already moved it as far (upstream: hop <= mine; downstream: hop >= mine; any ender transmitter) cancels the relay.
- Pocket computers don't relay.

## Kinds

### Turtle → server

**`hello`** (on boot, after recovery)
`label, version, gps (bool), cfg` (cfg = table of the effective config, small values only)

**`status`** (every `STATUS_INTERVAL` s, and immediately on phase change)
| Field | Type |
|-------|------|
| `label` | string |
| `version` | string |
| `phase` | string, one of the phases in INTERFACES.md |
| `reason` | string or nil, short human text ("chest full", "unbreakable block at 12,-58,40") |
| `pos` | `{x,y,z}` |
| `facing` | 0-3 |
| `home` | `{x,y,z}` |
| `gps` | bool, coordinates are world coordinates |
| `fuel` | number or `"unlimited"` |
| `fuelNeeded` | number, fuel needed to get home with margin |
| `slotsUsed` | 0-16 |
| `job` | `{corridor, branch, side, step}` |
| `stats` | `{ores, blocks, trips, uptime}` |
| `lastError` | string or nil (max 200 chars) |
| `cfg` | `{targetY, focus}` |

**`event`**: `level` (`"info"|"warn"|"error"`), `text` (max 200 chars), `eid` (`"<id>:<boot>:<n>"`, unique per event). Used for things worth logging (vein found, refuelled, recovered from crash). Not per block. Sent only in contact; otherwise buffered for `catchup`.

**`away`** (just before leaving home, phase `TO_WORK`): `label`, `est` (seconds the trip is expected to take), `eta` (epoch ms, sender clock). The estimate is the whole remaining job (moves × measured seconds per move, default 1.5 s), capped by what the fuel allows and by the measured length of full trips (`st.stats.tripSec`/`lastTripSec`, inventory-full or low-fuel trips only), at least 60 s. The server computes the ETA as receive time + `est`, shows `AWAY "away, back by ~hh:mm"` while the turtle is silent, and alerts `OVERDUE` only after `since + 1.5 × (eta − since) + 2 min`. Cleared by a `status` with phase `UNLOADING`, `REFUELING`, `IDLE` or `DONE`.

**`catchup`** (once, when contact returns): `events` = array of `{eid, ts, last, n, level, text}` (max 50, oldest info entries dropped first; repeats with the same text apart from numbers are coalesced: `n` = count, `ts` = first, `last` = latest, `text` = latest), `dropped` (number). The server logs each entry once (by `eid`) at its original time `ts`, sorted into `miner_events.log`, marked `(catch-up)`, with `(xN)` when `n > 1`.

**`ack`**: `id` (the cmd id), `ok` (bool), `err` (string or nil). Sent on receipt of a `cmd` addressed to this turtle.

### Store-and-forward (server)

A command to a turtle the server hasn't heard for 30 s is **queued** (card: `CMD: queued`), not sent. Any message from that turtle (any kind it sends) makes the server send its queued commands at once; without an ack within the normal retries (3 s × 4) the command goes back to queued and is sent again the next time the turtle is heard, until acked. A queued command expires after 24 h (`QUEUE_EXPIRE_MS`, top of `servers/tm_db.lua`) or when a newer command of the same kind (same `cmd`; for `SET` the same key) for the same turtle is issued (`err = "replaced"`). Turtles ack repeats of a cmd id without applying them again.

**`home_save`**: `home, homeFacing, gps`. Backup of the home record on the server. Sent when home is first set or changed.

**`home_get`**: no fields. Asks the server for this turtle's home record.

**`home_clear`**: no fields. Sent by `install` when the turtle is set up with no local state: every server deletes its home record for `from` (the miner sends a fresh `home_save` on its first start).

### Server → turtle

**`cmd`**: `id` (string, unique per command), `cmd` (string), `params` (table)

| cmd | params | Turtle behaviour |
|-----|--------|------------------|
| `RETURN_HOME` | | Stop the job step, go home, unload, then `IDLE` |
| `PAUSE` | | Stop where it is (`PAUSED`), keep reporting |
| `RESUME` | | From `PAUSED`/`IDLE`/`NEEDS_HELP`: continue the job. From `DONE`: continue if `MAX_CORRIDORS` was raised or `RESET_JOB` was sent |
| `SET` | `key, value` | Change a config key (see config.lua `REMOTE_KEYS`), persist it. `HOME_Y` on a no-GPS turtle is refused unless it is at home |
| `REQUEST_STATUS` | | Send `status` now |
| `RESET_JOB` | | Next time at home, restart the grid at corridor 0 |
| `RESET_HOME` | | "You are at home now": set home = current pos, facing as given in `params.facing` (or current) |
| `UPDATE` | | Run updater next time at home (at once if `IDLE`/`DONE` there), then carry on with what it was doing (after the reboot too, if files were installed) |
| `REBOOT` | | Save and `os.reboot()`, only when not moving |

**`home`**: `found (bool), home, homeFacing, gps`. Reply to `home_get`.

### Server → pocket / any listener

**`fleet`** (every 5 s, `to = "all"`)
`turtles`: array of the latest `status` tables, each with an added `id` (turtle computer ID), `lastSeen` (ms epoch on the server), `alert` (string or nil: `"NEEDS_HELP"`, `"ERROR"`, `"SILENT"`, `"OVERDUE"`), `away` (`{since, eta}` or nil) and `queued` (number of queued commands or nil). The heartbeat that keeps turtles in contact.
`server`: `{id, label}`

### Pocket → server

**`cmd_relay`**: `target` (turtle id), `cmd`, `params`, `id`. The server issues it like its own command (queued if the turtle isn't heard) and forwards the turtle's `ack` back as `kind="ack"`, `to = pocket id`, fields `{id, ok, err, target}`. When it queues the command it answers at once with `{id, queued=true, target}`; the pocket shows `queued` and stops retrying; the final ack follows when the turtle acks (or `ok=false` with `err="expired"`/`"replaced"`).

## Duplicate handling

- Server command retries reuse the same `cmd.id` with a new envelope `seq`. Turtles keep recent cmd ids and re-ack repeats without executing them again.
- Only the cluster leader answers `home_get` (and owns the command queue), so a turtle gets one answer however many server PCs there are. Turtles still wait the full timeout unless a `found=true` reply arrives, and prefer `found=true` over `found=false` (older servers, split clusters).
- `FOCUS` values are short family names (`"diamond"`, `"iron"`, `"ancient_debris"`); the miner matches them as a substring of the ore family.

## Cluster (server PCs, same `TMINER` protocol)

Every server PC runs `tminer_server` (docs/CLUSTER_GPS_PLAN.md). The PCs form one cluster over any modem mix: cluster messages are relayed like everything else (mesh), with `to = "cluster"` (all members) or a member id. Turtles never relay them (`ohop = 0`, `to` is not `"server"`). Pocket computers are not members. Body fields use `dseq` for the data version, because `seq` is the envelope's.

**Data version**: `epoch` (number of the leadership that wrote it; a new leader takes max known + 1) and `dseq` (number of changes applied). Newer = higher epoch, then higher dseq.

| kind | from → to | fields | when |
|------|-----------|--------|------|
| `cluster_hello` | any member → `"cluster"` | `role` (`"joining"`, `"electing"`, `"replica"`, `"leader"`), `leader` (id it follows or nil), `epoch`, `dseq`, `roles` (`{ui, gateway, link, update, gps, member}` booleans), `label` | at boot, every 5 s, and at once in reply to a hello from a joining/electing PC (at most once a second) |
| `cluster_leader` | leader → `"cluster"` | `epoch`, `dseq` | on taking over, in reply to a hello from a PC that doesn't follow it, and when it hears a rival leader it beats (at most once a second) |
| `cluster_delta` | leader → `"cluster"` | `epoch`, `base` (dseq before), `dseq` (after), `d` = `{turtles, homes, pending, done, log}`; map values `false` = deleted; `log` = array of `{ms, text}` | at once (next 0.5 s tick) when the command queue or homes change, else every 5 s (empty `d` = heartbeat, `base == dseq`) |
| `cluster_snap_req` | replica → leader id | `epoch`, `dseq` | when a delta doesn't fit (`epoch` differs or `base` ≠ own dseq), after following a new leader; every 3 s until answered |
| `cluster_snapshot` | leader → requester or `"cluster"` | `epoch`, `dseq`, `db` = `{turtles, homes, pending, done, log}` (`log` = array of lines) | on request; broadcast once on taking over. Pending changes are flushed as a delta first, so nothing arrives twice |
| `cluster_fwd` | member → leader id | `op = "cmd"`: `id, target, cmd, params, origin` (a UI command, or a pocket's `cmd_relay` with `origin` = pocket id). `op = "merge"`: `pending` (queued commands by id), `homes` | `cmd`: at once, resent every 5 s (also to a new leader) until the id shows up in the replicated `pending` or `done`. `merge`: once, by a leader stepping down |

Rules:
- **Join**: a booting PC sends `cluster_hello` (`role = "joining"`) and follows the first leader it hears. No leader within 3 s: election. No modem: it leads alone.
- **Election**: among itself and the members heard in the last 15 s, the newest data (epoch, dseq) wins, then the lowest computer ID. The winner sends `cluster_leader` and a snapshot; the others wait for it (15 s, then they drop it and elect again). A live leader is never replaced by a newcomer, so a rebooted old leader rejoins as a replica.
- **Failover**: a replica that hears nothing from its leader for 15 s marks it gone, sends a hello (`role = "electing"`), collects hellos for 2 s and elects. The new leader keeps the replicated queue: every pending command becomes queued and goes out when its turtle is next heard (same `id`, so a turtle that already had it only re-acks).
- **Two leaders** (a split network healed): the one with the higher epoch, then the lower ID, stays. The other sends `cluster_fwd op="merge"` (its queued commands and homes; the leader adds commands it has no id or same-kind command for, and homes newer by `at`), then follows and takes a snapshot.
- **Leader only**: acts on turtle messages (status, events, away, catch-up, acks), answers `home_get`, stores `home_save`/`home_clear`, owns and transmits commands, sends `fleet`, writes the event log. Replicas relay, show the replicated data, and forward UI commands.
- **Update server**: of the live members with `roles.update`, only the lowest ID answers `update_check` / `file_get`.

## Update sub-protocol (same `TMINER` protocol)

| kind | direction | fields |
|------|-----------|--------|
| `update_check` | turtle → server | `role` (`"miner"`) |
| `update_manifest` | update server → turtle | `files`: array of `{name, version}` |
| `file_get` | turtle → update server | `name` |
| `file` | update server → turtle | `name, version, content` |

Versions are read from the first line of each file: `-- Version: x.y.z`.

## Timing

- Turtle status: every 10 s (config `STATUS_INTERVAL`), plus on phase change.
- Server marks a turtle `SILENT` after 60 s without any message, unless it announced `away` and is not overdue (then `AWAY`, no alert; overdue: `OVERDUE`).
- Command ACK timeout: 3 s, retried 3 times by the server, then queued until the turtle is heard again (24 h max).
- Contact window: 30 s. Server `fleet` every 5 s (cluster leader only).
- Cluster: hello every 5 s, delta at once on queue/home changes else every 5 s, leader gone after 15 s silence (+2 s election), join window 3 s, role re-check every 60 s.
