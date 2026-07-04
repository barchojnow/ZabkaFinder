# ZabkaFinder

A Garmin Connect IQ **widget** for watches that points you to the
nearest [Żabka](https://zabka.pl) convenience store. It shows a
rotating on-screen arrow and the distance in meters, updated live as
you walk.

## How it works

1. On start, the widget requests continuous GPS updates
   (`Position.LOCATION_CONTINUOUS`).
2. On the first GPS fix, it sends a query to the public
   [Overpass API](https://overpass-api.de/) (an OpenStreetMap data
   service) asking for every node, way, or relation (`nwr`) within a
   500 meter radius whose name matches `abka` (case-insensitive) —
   i.e. "Żabka" / "Zabka" — and picks the **nearest** one (Overpass
   does not guarantee results are sorted by distance). Querying
   `nwr` instead of just `node` matters because many real shops are
   mapped as a building outline rather than a single point.
3. Once a match is picked, the widget computes:
   - the great-circle **distance** to the store using the
     [Haversine formula](https://en.wikipedia.org/wiki/Haversine_formula)
     (Earth radius ≈ 6,371,000 m), and
   - the **initial compass bearing** towards it.
4. The on-screen arrow eases towards the target angle (device compass
   heading minus bearing to the store) on every redraw instead of
   snapping instantly, which smooths out jitter from noisy compass
   readings.
5. The arrow and distance readout change color depending on state:
   gray while searching, orange once the store is found, and green
   with a small pulsing dot once you're within ~30 m of it.
6. Only one Overpass request is in flight at a time, bounded by a
   25-second client-side watchdog timer — if a response (success or
   error) doesn't arrive in time, the request is abandoned outright
   so the widget never gets stuck showing "szukam zabki..."
   indefinitely, regardless of why the network call didn't complete.
   Any failure (a real error, an HTTP 406, or a watchdog timeout)
   rotates to the next mirror in a small built-in list
   (`overpass.private.coffee`, `overpass.kumi.systems`,
   `overpass-api.de`) and retries with a growing backoff (5s, 10s,
   15s, … capped at 30s). If a request succeeds but finds nothing
   nearby, it quietly re-checks every 10 seconds as you keep walking,
   without spamming the API.

## Project structure

```
manifest.xml                 Connect IQ app manifest (permissions, target devices, etc.)
monkey.jungle                 Build configuration
source/
  ZabkaFinderApp.mc            Application entry point
  ZabkaFinderView.mc            Main (and only) view: GPS, API calls, drawing
resources/
  drawables/                    App icon and logo bitmaps
  layouts/                      Layout XML (currently unused placeholder layout)
  strings/                      Localized strings (app name)
```

## Requirements

- [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
- A Garmin device (or simulator) with GPS, a compass sensor, and
  Wi-Fi/Bluetooth connectivity for network requests
- Target device: Venu 2 (see `manifest.xml`; more devices can be added)

## Permissions used

Declared in `manifest.xml`:

- `Communications` — to call the Overpass API
- `Positioning` — to read GPS location
- `Sensor` — to read the compass heading

## Building & running

Using the Connect IQ VS Code extension:

1. Open this folder in VS Code with the Monkey C extension installed.
2. Run **"Monkey C: Build Current Project"** or **"Monkey C: Run"**
   to launch it in the simulator.

Or from the command line with the Connect IQ SDK tools (`monkeyc`,
`monkeydo`) — see the
[Connect IQ SDK docs](https://developer.garmin.com/connect-iq/reference-guides/monkey-c-command-line-setup/)
for details.

## Known limitations / ideas for improvement

- Once a store is found, the widget keeps tracking that same store
  even if you walk far enough that a different one would now be
  closer — it doesn't continuously re-search.
- The primary Overpass instance (`overpass-api.de`) has been
  intermittently rejecting legitimate requests with HTTP 406 (see
  [Overpass-API#791](https://github.com/drolbr/Overpass-API/issues/791)).
  The widget now rotates through a couple of mirrors automatically
  (see above), but if all configured mirrors start doing the same,
  the endpoint list in `ZabkaFinderView.mc` (`OVERPASS_ENDPOINTS`)
  will need updating.
- Currently targets a single device (Venu 2); more devices can be
  added in `manifest.xml`.
- No haptic/vibration feedback when arriving at the store.
- No support for favorites or showing more than one nearby store at
  a time.

## License

This project is open source — see [LICENSE](LICENSE).
