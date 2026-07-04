# ZabkaFinder

A Garmin Connect IQ **widget** for watches that points you to the
nearest [Żabka](https://zabka.pl) convenience store. It shows a
rotating on-screen arrow and the distance in meters, updated live as
you walk.

## How it works

1. On start, the widget requests continuous GPS updates
   (`Position.LOCATION_CONTINUOUS`).
2. On the first GPS fix, it sends a search query to the
   [Nominatim API](https://nominatim.org/) (OpenStreetMap's
   search/geocoding service — the same one behind the search box on
   openstreetmap.org) for places named "Zabka", restricted to a
   bounding box of roughly 500 meters around the current position,
   and picks the **nearest** matching result (Nominatim ranks by
   relevance, not strictly by distance). The app previously used the
   Overpass API directly, but switched to Nominatim after Overpass's
   volunteer-run public infrastructure became intermittently
   unusable (see "Known limitations" below for the history).
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
6. Only one Nominatim request is in flight at a time, bounded by a
   25-second client-side watchdog timer — if a response (success or
   error) doesn't arrive in time, the request is abandoned outright
   so the widget never gets stuck showing "szukam zabki..."
   indefinitely, regardless of why the network call didn't complete.
   Any failure retries with a growing backoff (5s, 10s, 15s, …
   capped at 30s). If a request succeeds but finds nothing nearby, it
   quietly re-checks every 10 seconds as you keep walking, without
   spamming the API.

## Usage of the Nominatim API

This widget follows [Nominatim's usage
policy](https://operations.osmfoundation.org/policies/nominatim/) for
its shared public instance:
- **Rate**: at most one request in flight at a time, with a minimum
  5-second backoff between retries — far under the 1 request/second
  limit.
- **Identification**: requests send a descriptive `User-Agent` header.
- **Attribution**: results are © OpenStreetMap contributors, ODbL
  1.0 — see [openstreetmap.org/copyright](https://www.openstreetmap.org/copyright).

If this widget were to become widely used, running a self-hosted
Nominatim (or Overpass) instance would be the considerate next step
rather than relying indefinitely on the shared public one.

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

- `Communications` — to call the Nominatim API
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
- **History**: this widget originally used the Overpass API
  directly. As of mid-2026 the primary Overpass instance
  (`overpass-api.de`) was intermittently rejecting legitimate
  requests with HTTP 406 (see
  [Overpass-API#791](https://github.com/drolbr/Overpass-API/issues/791)),
  and the community mirrors that absorbed the redirected traffic
  became overloaded in turn — a widely reported, ecosystem-wide
  issue at the time, not specific to this app. The widget was
  switched to Nominatim as a result; see "How it works" above.
- Nominatim returns a capped, relevance-ranked "collection of best
  matches" (`limit=20` here) rather than an exhaustive enumeration
  like Overpass does — in an unusually dense cluster of matching
  results this could in theory miss the true nearest one, though in
  practice this hasn't been an issue for a single small area.
- Currently targets a single device (Venu 2); more devices can be
  added in `manifest.xml`.
- No haptic/vibration feedback when arriving at the store.
- No support for favorites or showing more than one nearby store at
  a time.

## License

This project is open source — see [LICENSE](LICENSE).
