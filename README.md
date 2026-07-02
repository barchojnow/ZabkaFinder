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
   service) asking for any node within a 500 meter radius whose name
   matches `abka` (case-insensitive) — i.e. "Żabka" / "Zabka".
3. Once a match is returned, the widget computes:
   - the great-circle **distance** to the store using the
     [Haversine formula](https://en.wikipedia.org/wiki/Haversine_formula)
     (Earth radius ≈ 6,371,000 m), and
   - the **initial compass bearing** towards it.
4. The on-screen arrow is continuously re-rotated using the device's
   compass heading (`Sensor.Info.heading`) minus the bearing to the
   store, so it always points the right way as you turn.
5. To avoid hammering the API, only **one** Overpass request is sent
   per GPS session (tracked via the `apiRequested` flag); after that,
   distance/bearing are simply recalculated locally as your position
   updates.

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

- Only the *first* matching Overpass result is used — it may not
  always be the closest one if several are returned.
- If the Overpass request fails, the widget does not automatically
  retry on the next GPS fix (by design, to avoid spamming the API).
- The Overpass endpoint (`overpass-api.de`) is a shared public
  instance with rate limits; consider adding a fallback mirror for
  reliability.
- Currently targets a single device (Venu 2); more devices can be
  added in `manifest.xml`.

## License

This project is open source — see [LICENSE](LICENSE).
