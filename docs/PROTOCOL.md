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

Dedupe key: `from .. ":" .. boot .. ":" .. seq`. Receivers keep the last 256 keys and ignore repeats.

## Relay rules

- Only servers (monitor computers) relay. Turtles and pocket computers never relay.
- A server relays every `TMINER` message it hasn't seen before, with `hops + 1`, via `rednet.broadcast` (goes out on every open modem). It never changes `from`.
- `fleet` messages are not relayed (each server sends its own).

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

**`event`**: `level` (`"info"|"warn"|"error"`), `text` (max 200 chars). Used for things worth logging (vein found, refuelled, recovered from crash). Not per block.

**`ack`**: `id` (the cmd id), `ok` (bool), `err` (string or nil). Sent on receipt of a `cmd` addressed to this turtle.

**`home_save`**: `home, homeFacing, gps`. Backup of the home record on the server. Sent when home is first set or changed.

**`home_get`**: no fields. Asks the server for this turtle's home record.

### Server → turtle

**`cmd`**: `id` (string, unique per command), `cmd` (string), `params` (table)

| cmd | params | Turtle behaviour |
|-----|--------|------------------|
| `RETURN_HOME` | | Stop the job step, go home, unload, then `IDLE` |
| `PAUSE` | | Stop where it is (`PAUSED`), keep reporting |
| `RESUME` | | From `PAUSED`/`IDLE`/`NEEDS_HELP`: continue the job |
| `SET` | `key, value` | Change a config key (see config.lua `REMOTE_KEYS`), persist it |
| `REQUEST_STATUS` | | Send `status` now |
| `RESET_JOB` | | Next time at home, restart the grid at corridor 0 |
| `RESET_HOME` | | "You are at home now": set home = current pos, facing as given in `params.facing` (or current) |
| `UPDATE` | | Run updater when next `IDLE` at home |
| `REBOOT` | | Save and `os.reboot()`, only when not moving |

**`home`**: `found (bool), home, homeFacing, gps`. Reply to `home_get`.

### Server → pocket / any listener

**`fleet`** (every 5 s, `to = "all"`)
`turtles`: array of the latest `status` tables, each with an added `id` (turtle computer ID), `lastSeen` (ms epoch on the server) and `alert` (string or nil: `"NEEDS_HELP"`, `"ERROR"`, `"SILENT"`).
`server`: `{id, label}`

### Pocket → server

**`cmd_relay`**: `target` (turtle id), `cmd`, `params`, `id`. The server re-sends it as a `cmd` to `target` and forwards the turtle's `ack` back as `kind="ack"`, `to = pocket id`, fields `{id, ok, err, target}`. If the turtle never acks, the server sends `ok=false, err="no ack"`.

## Duplicate handling

- Server command retries reuse the same `cmd.id` with a new envelope `seq`. Turtles keep recent cmd ids and re-ack repeats without executing them again.
- Every server answers `home_get`. Turtles wait the full timeout unless a `found=true` reply arrives, and prefer `found=true` over `found=false`.
- `FOCUS` values are short family names (`"diamond"`, `"iron"`, `"ancient_debris"`); the miner matches them as a substring of the ore family.

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
- Server marks a turtle `SILENT` after 60 s without any message.
- Command ACK timeout: 3 s, retried 3 times by the server, then shown as failed on the card.
