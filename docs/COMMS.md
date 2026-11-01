# Comms model (mixed modems, mostly out of range)

Facts from CC:Tweaked source (`WirelessModemPeripheral`, `WirelessNetwork`, `Config`, mc-1.20.x):

| Fact | Detail |
|------|--------|
| Basic wireless range | 64 blocks at or below Y 96; rises linearly above Y 96 to 384 at build height. Storm defaults are the same. |
| Distance | Straight-line 3D. Blocks don't attenuate. |
| Who needs range | `max(sender range, receiver range)`: either end's range is enough. |
| Ender (advanced) modem | Unlimited range in the dimension, and cross-dimension. **If either end is an ender modem, the message is delivered.** |
| GPS | Same rules. Hosts with ender modems give fixes to basic-modem turtles anywhere in the dimension (the reply carries the true distance). Hosts with basic modems reach nobody at Y -58 from a normal surface tower. |
| Turtle slots | A mining turtle has one free side: one modem only. |

Consequences:
- Home around Y 70, mining at Y -58: a basic-modem turtle loses contact with a basic-modem master about 60 blocks down the shaft. Raising the master doesn't solve it (even at Y 319 it only reaches Y -58 nearly straight below).
- **One ender modem anywhere (master, relay computer, or one turtle) acts as a hub:** it hears every wireless modem in the dimension and everyone hears it. That is the bridge.
- Early game (no ender modems): turtles work blind and talk to the master only near home.

## Design rules

1. **Nothing depends on contact.** Mining, recovery and fuel are fully local (already true). GPS-mode turtles fall back to blind recovery when GPS is unreachable (in progress, blind-turtle agent).
2. **Store-and-forward commands.** The server keeps commands queued per turtle (shown as "queued") and delivers them when the turtle is next heard. Turtles check in on every phase change and when they arrive home. Queued commands expire after a configurable time (default 24 h) or when replaced by a newer command of the same kind.
3. **Expected absence, not false alarms.** Before leaving home the turtle sends `away` with an ETA (from job size, fuel, and its own measured trip times). The monitor shows "away, back by ~hh:mm". Alert only when overdue by 50% + 2 min, or when a turtle reports NEEDS_HELP/ERROR.
4. **Catch-up log.** While out of contact the turtle buffers events (veins, problems, ore counts; max 50 entries, coalesced). On contact it sends one `catchup` message; the monitor merges it into the event log with original timestamps.
5. **Bridge (mixed modems).** Any computer or turtle relays `TMINER` traffic (dedupe + hop limit):
   - Ender-modem nodes always relay (they are hubs by nature).
   - Basic-modem turtles relay using the distance-to-server rule from ARMY_PLAN §5 (only if it moves the message closer).
   - `relay` program for a plain computer: auto-detects its modems (ender, wireless, wired) and relays between all of them. Place one with an ender modem anywhere for full coverage, or one with a basic modem at the shaft bottom for 64 blocks around it.
6. **How a turtle knows it's in contact:** it heard any server/relay message within the last 30 s. Status sends while out of contact are skipped (no wasted work); the latest status goes out as soon as contact returns.

## Recommended setups

| You have | Do this | Result |
|----------|---------|--------|
| No modems | Turtles run blind, keyboard controls | Works; no monitor |
| Basic modems only | Master at home; optional relay computer at the shaft bottom | Contact near home (and around the relay); store-and-forward covers the rest |
| One ender modem | Put it on the master or a relay computer | Every turtle with any modem is in contact everywhere |
| 4 ender modems | Use them on the GPS hosts | GPS at any depth for every turtle with a modem |
