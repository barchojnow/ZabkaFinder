# ZabkaFinder

A Garmin Connect IQ **widget** for watches that points you to the
nearest [Żabka](https://zabka.pl) convenience store. It shows a
rotating on-screen arrow and the distance in meters, updated live as
you walk — and lets you pick from the 5 nearest stores in a menu.

## How it works

1. On start, the widget requests continuous GPS updates
   (`Position.LOCATION_CONTINUOUS`).
2. On the first GPS fix, it sends a search query to the
   [Nominatim API](https://nominatim.org/) (OpenStreetMap's
   search/geocoding service — the same one behind the search box on
   openstreetmap.org) for places named "Zabka", restricted to a
   bounding box of roughly 1 km around the current position.
   The app previously used the Overpass API directly, but switched to
   Nominatim after Overpass's volunteer-run public infrastructure
   became intermittently unusable (see "Known limitations" below for
   the history).
3. All returned results (up to 20) are filtered to the true 1 km
   circular radius, sorted ascending by great-circle **distance**
   ([Haversine formula](https://en.wikipedia.org/wiki/Haversine_formula),
   Earth radius ≈ 6,371,000 m), and the widget locks onto the nearest
   one, computing the **initial compass bearing** towards it. Fresh
   results are **merged** with previously known stores still in range
   (duplicates detected within 25 m), so the list only gains
   knowledge as you walk even when Nominatim's relevance ranking
   drops a result between calls.
4. **Store selection menu**: tapping the screen (touch devices) or
   pressing START (button devices) opens a native `Menu2` listing the
   5 nearest stores — street address as the title, live distance as
   the subtitle. Picking one retargets the arrow. GPS and the compass
   keep running while the menu is open, so distances stay fresh and
   there's no fix re-acquisition after returning.
5. **Hybrid heading**: while walking (ground speed ≥ 1 m/s) the arrow
   is driven by the GPS course-over-ground, which is immune to
   compass miscalibration and wrist tilt; when standing still it
   falls back to the magnetic compass. The arrow eases towards the
   target angle (heading minus bearing to the store) on every redraw
   instead of snapping instantly, which smooths out jitter from noisy
   readings.
6. The arrow and distance readout change color depending on state:
   gray while searching, orange once the store is found, and green
   with a small pulsing dot once you're within ~30 m of it. Crossing
   the 30 m line also fires a short **double vibration**
   (`Attention.vibrate`) — exactly once per approach: the trigger
   re-arms only after walking back out past 50 m (hysteresis), or
   when a new store is picked from the menu.
7. **Background re-search**: after walking more than 100 m from
   where the last search ran (and at most once per 30 s; opening the
   store menu also nudges a refresh under the same conditions), the
   widget silently refreshes the store list. In automatic mode the
   arrow switches to whichever store is now nearest; a store picked
   manually from the menu is never overridden — only the menu list
   updates. Refresh errors are silent while a target is already
   locked.
8. **Walking-away guard**: when you picked a store manually and then
   drift more than 75 m above the closest you've been to it, the
   widget vibrates and shows a 15-second prompt: tap/START to keep
   navigating to your choice, MENU to pick a different store from
   the list, or do nothing — after the countdown it automatically
   retargets to the nearest store (with a closing vibration).
9. Only one Nominatim request is in flight at a time, bounded by a
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
manifest.xml                  Connect IQ app manifest (permissions, target devices, etc.)
monkey.jungle                 Build configuration + per-device launcher icon mapping
source/
  ZabkaFinderApp.mc           Application entry point (wires view + input delegate)
  ZabkaFinderView.mc          Main view: UI state, GPS/compass handling, drawing
  ZabkaFinderDelegate.mc      Input handling + the 5-nearest-stores Menu2
  NominatimClient.mc          Nominatim requests, watchdog, retry backoff, GeoJSON parsing
  GeoMath.mc                  Pure math: Haversine distance, bearing, angle normalization
resources/
  drawables/                  App icon and logo bitmaps (base, 416x416 screens)
  layouts/                    Layout XML (currently unused placeholder layout)
  strings/                    UI strings - English (default language)
resources-pol/
  strings/                    Polish strings (auto-selected on Polish-language watches)
variants/                     Per-device-class drawables, mapped in monkey.jungle:
  small-218 … small-280       pre-scaled logo + 40px launcher icon (Fenix 7, FR 255/955)
  mid-360                     logo 69px + 60px launcher icon (FR 265S)
  large-416-60 / -70          launcher icon only, logo from base (Epix 2/FR 265, Venu 2)
  large-454                   logo 87px + 65px launcher icon (FR 965)
```

The UI layout is resolution-independent: all pixel offsets are scaled
by `screenWidth / 416` (the Venu 2 reference size), fonts drop one
size on screens narrower than 300 px, and logo/launcher bitmaps are
shipped pre-scaled per device class via the `variants/` mappings in
`monkey.jungle` (they can't live inside `resources/`, which is
compiled in full for every device).

## Requirements

- [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
  — with device files for all target devices downloaded via the SDK
  Manager
- A Garmin device (or simulator) with GPS, a compass sensor, and
  Wi-Fi/Bluetooth connectivity for network requests

### Supported devices

Declared in `manifest.xml` (`minApiLevel 4.0.0`):

| Series | Product IDs |
|---|---|
| Venu 2 | `venu2` |
| Fenix 7 | `fenix7`, `fenix7s`, `fenix7x` |
| Epix (Gen 2) | `epix2` |
| Forerunner 255 | `fr255`, `fr255m`, `fr255s`, `fr255sm` |
| Forerunner 265 | `fr265`, `fr265s` |
| Forerunner 955 / 965 | `fr955`, `fr965` |

On touch devices the store menu opens with a screen tap; on 5-button
devices (Fenix, Forerunner) with the START key.

### Languages

English (default) and Polish, selected automatically from the
watch's system language. All UI strings live in
`resources/strings/strings.xml` (English) with Polish overrides in
`resources-pol/strings/strings.xml`.

## Permissions used

Declared in `manifest.xml`:

- `Communications` — to call the Nominatim API
- `Positioning` — to read GPS location
- `Sensor` — to read the compass heading

(`Attention.vibrate` requires no manifest permission.)

## Building & running

Using the Monkey C VS Code extension:

1. Open this folder in VS Code with the Monkey C extension installed.
2. Press **F5** and pick a launch configuration from
   `.vscode/launch.json` — either a fixed device ("Run Venu 2",
   "Run Fenix 7", "Run Forerunner 965") or "Run App", which prompts
   for a device each time.
3. **"Monkey C: Export Project"** compiles a release `.iq` for every
   device in the manifest at once — useful as a quick all-devices
   compile check.

Or from the command line with the Connect IQ SDK tools (`monkeyc`,
`monkeydo`) — see the
[Connect IQ SDK docs](https://developer.garmin.com/connect-iq/reference-guides/monkey-c-command-line-setup/)
for details.

## Known limitations / ideas for improvement

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
- Store addresses come from OSM `addressdetails`; stores with
  incomplete OSM data fall back to a generic "Zabka" label in the
  menu. Polish diacritics are folded to ASCII for font compatibility.
- No support for favorites.

## Privacy

See [PRIVACY.md](PRIVACY.md) — the short version: the only data that
ever leaves the watch is an approximate location sent to Nominatim to
find nearby stores; nothing is collected or stored by the app.

## License

This project is open source — see [LICENSE](LICENSE).
