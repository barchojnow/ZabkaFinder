# ZabkaFinder

A Garmin Connect IQ **widget** for watches that points you to the
nearest [Żabka](https://zabka.pl) convenience store. It shows a
rotating on-screen arrow and the distance in meters, updated live as
you walk — and lets you pick from the 5 nearest stores in a menu.

## How it works

1. On start, the widget requests continuous GPS updates using the
   **device's default positioning mode**, and escalates only if that
   fails: no fix within 15 s → ask for the best GNSS configuration
   the watch reports (SatIQ, all-systems multi-band, all-systems);
   still nothing after 25 s → fall back to the default and stay
   there. Escalation is skipped entirely while the GNSS engine
   reports progress, because every `enableLocationEvents` call
   restarts satellite acquisition.

   Default-first is deliberate. Asking for a "better" configuration
   up front looks tempting, but `hasConfigurationSupport()` only
   reports what the *hardware* knows — not what the firmware actually
   serves to a widget. Fenix 7 and Epix Pro accept such a request and
   then deliver no position at all, which is exactly how v1.1.1
   broke them. With 66 devices and no way to test them, the only safe
   order is "start with what already works everywhere".
2. On the first GPS fix, it sends a search query to the
   [Nominatim API](https://nominatim.org/) (OpenStreetMap's
   search/geocoding service — the same one behind the search box on
   openstreetmap.org) for places named "Zabka", restricted to a
   bounding box of roughly 1 km around the current position.
   The app previously used the Overpass API directly, but switched to
   Nominatim after Overpass's volunteer-run public infrastructure
   became intermittently unusable (see "Known limitations" below for
   the history).
3. All returned results (up to 15) are filtered to the true 1 km
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
   falls back to the magnetic compass. Watches with **no compass at
   all** (Forerunner 55, original Venu Sq) use the GPS course as the
   only source, from a gentle walking pace (0.5 m/s). Until some
   heading is available the arrow stays **gray** — a meaningless
   direction is worse than none. The arrow eases towards the target
   angle (heading minus bearing to the store) on every redraw
   instead of snapping instantly, which smooths out jitter.
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
   so the widget never gets stuck on "searching for Zabka..."
   indefinitely, regardless of why the network call didn't complete.
   Any failure retries with a growing backoff (5s, 10s, 15s, …
   capped at 30s). If a request succeeds but finds nothing nearby, it
   quietly re-checks every 10 seconds as you keep walking, without
   spamming the API.
10. **Error messages are rules, not lookup tables**: HTTP statuses are
    positive, Connect IQ transport errors are negative — so `-104`
    becomes "connect your phone", every other negative code becomes
    "no internet", and positive codes are shown with their number
    because they describe the server rather than the user's setup.
    That way a new transport error code doesn't need a new release.

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
monkey.jungle                 Build config + per-device resource variant mapping
PRIVACY.md                    Privacy policy (linked from the store listing)
source/
  ZabkaFinderApp.mc           Application entry point (wires view + input delegate)
  ZabkaFinderView.mc          Main view: lifecycle, GPS/compass handling, drawing
  ZabkaFinderDelegate.mc      Input handling + the 5-nearest-stores Menu2
  NominatimClient.mc          Nominatim requests, watchdog, retry backoff, GeoJSON parsing
  StoreList.mc                Store collection: radius filtering, merging, sorting
  ProximityAlerts.mc          Arrival vibration + walking-away prompt state machines
  TextFit.mc                  Adaptive font sizing for round screens
  GeoMath.mc                  Pure math: Haversine distance, bearing, angle normalization
  Effects.mc                  Vibrator + Scheduler: the injectable side effects
  tests/                      Unit tests, (:test) annotated (GeoMath, StoreList, ProximityAlerts)
tools/
  run-tests.ps1               Runs the test suite across several devices in one command
resources/
  drawables/                  App icon and logo bitmaps (base, 416x416 screens)
  layouts/                    Layout XML (currently unused placeholder layout)
  strings/                    UI strings - English (default language)
resources-pol/
  strings/                    Polish strings (auto-selected on Polish-language watches)
variants/                     Per-device drawables, mapped in monkey.jungle:
  small-208 … small-280       pre-scaled logo + launcher icon (208/218/240/260/280 px screens)
  mid-360, mid-390            logo 69/75px + launcher icon
  large-416-60 / -70          launcher icon only, logo from base (416 px screens)
  large-454                   logo 87px + 65px launcher icon
  launcher-36 … launcher-70   launcher icon only, layered on top of a screen variant
                              where a device's icon size doesn't match its screen class
store_assets/                 Store listing graphics and screenshots (not part of the build)
```

Two things make one binary fit 66 different watches:

- **Layout scales with the screen.** Every pixel offset is multiplied
  by `screenWidth / 416` (the Venu 2 reference size), and text picks
  the largest font that fits the round screen's *chord* at its own
  vertical position (`TextFit`) — so labels never clip, whatever the
  language or screen size.
- **Bitmaps are pre-scaled per device**, since runtime scaling isn't
  available everywhere and looks worse. The `variants/` folders can't
  live inside `resources/` (which is compiled in full for every
  device), so `monkey.jungle` maps each product to its variant path
  explicitly; the last path wins on conflicting resource ids, which
  is how `launcher-*` overrides just the icon.

## Requirements

- [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/)
  — with device files for all target devices downloaded via the SDK
  Manager
- A Garmin device (or simulator) with GPS and a phone connection for
  network requests. A magnetic compass is optional — watches without
  one derive heading from the GPS course while moving.

### Supported devices

Declared in `manifest.xml` (`minApiLevel 3.1.0`) — all round-screen
Fenix, Enduro, Epix, Forerunner and Venu models from the Fenix 5 /
FR 245 / Venu 1 generation onwards (65 products):

| Series | Product IDs |
|---|---|
| Fenix 5 | `fenix5`, `fenix5s`, `fenix5x`, `fenix5plus`, `fenix5splus`, `fenix5xplus` |
| Fenix 6 | `fenix6`, `fenix6pro`, `fenix6s`, `fenix6spro`, `fenix6xpro` |
| Fenix 7 | `fenix7`, `fenix7s`, `fenix7x`, `fenix7pro`, `fenix7pronowifi`, `fenix7spro`, `fenix7xpro`, `fenix7xpronowifi` |
| Fenix 8 / E | `fenix843mm`, `fenix847mm`, `fenix8pro47mm`, `fenix8solar47mm`, `fenix8solar51mm`, `fenixe` |
| Enduro | `enduro`, `enduro3` |
| Epix | `epix2`, `epix2pro42mm`, `epix2pro47mm`, `epix2pro51mm` |
| Forerunner | `fr55`, `fr70`, `fr165(m)`, `fr170(m)`, `fr245(m)`, `fr255(m/s/sm)`, `fr265(s)`, `fr57042mm`, `fr57047mm`, `fr645(m)`, `fr745`, `fr935`, `fr945(lte)`, `fr955`, `fr965`, `fr970` |
| Venu | `venu`, `venud`, `venu2`, `venu2plus`, `venu2s`, `venu3`, `venu3s`, `venu441mm`, `venu445mm` |

Not supported: devices below Connect IQ 3.1 (Fenix 3, Fenix Chronos,
FR 230/235/630/735XT/920XT — no `Menu2` API), FR 45 (no widget
support at all) and rectangular screens (Venu Sq/Sq 2, Venu X1) —
the layout is designed for round displays.

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

### Tests

`source/tests/` holds unit tests for the logic that can be verified
off-device — `GeoMath` (Haversine distance, initial bearing, angle
normalization), `StoreList` (radius filtering, merge/dedup, distance
sorting) and `ProximityAlerts` (arrival buzz, hysteresis, the
walking-away prompt). They use the Connect IQ test framework:
functions are annotated `(:test)`, so they're compiled into test
builds only and never ship in a release binary.

`ProximityAlerts` is testable because its two side effects — buzzing
and scheduling — are injected (`Effects.mc` in production, fakes in
tests). The state machine decides *when* to buzz; the test counts
buzzes and fires the timeout by hand instead of waiting 15 seconds.
That's how "exactly one vibration per approach", the rule the whole
latch-and-hysteresis design exists for, becomes an assertion rather
than a hope.

Run them with **"Monkey C: Run Tests"** in VS Code, or from the CLI
with `monkeydo <prg> <device> /t` (slash flags on Windows). Reference
distances were computed independently rather than captured from the
code, so a regression can't redefine its own expected result — and
several tests exist because the bug happened first: menu order that
froze at search time, and stores lost when a refresh omitted them.

`tools/run-tests.ps1` runs the suite across several devices in one
command (the simulator only runs one device at a time, so it loops):

```powershell
.\tools\run-tests.ps1                    # representative device set
.\tools\run-tests.ps1 -Devices venu2     # a single device
.\tools\run-tests.ps1 -All               # every product in the manifest
```

It starts the simulator if needed, prints a per-device summary and
exits non-zero on any failure. (If PowerShell blocks it, run
`powershell -ExecutionPolicy Bypass -File .\tools\run-tests.ps1`.)

The tested logic is device-independent, so the default set covers
what actually varies — tightest memory (`fr55`), oldest API
(`fenix5`), touch (`venu2`) and newest hardware (`fenix847mm`).
`-All` exists for completeness but takes ~30 minutes for little
extra signal; `Export Project` already proves the code compiles on
every product.

Or from the command line with the Connect IQ SDK tools (`monkeyc`,
`monkeydo`) — see the
[Connect IQ SDK docs](https://developer.garmin.com/connect-iq/reference-guides/monkey-c-command-line-setup/)
for details.

## Troubleshooting

**Stuck on "searching GPS..."** — the widget asks for the best
satellite mode the watch offers, but a cold start still needs open
sky. Sync the watch with Garmin Connect first (that downloads the
satellite prediction data; without it a first fix can take minutes),
then try outdoors rather than indoors or in a narrow street.

**The arrow stays gray / doesn't point anywhere** — some watches have
no magnetic compass (Forerunner 55, original Venu Sq). There the
direction comes from the GPS course, which only exists while you're
moving: take a few steps and the arrow colors up. Distance works
regardless.

**"connect your phone"** — Connect IQ apps reach the internet through
the phone's Bluetooth connection, so store search needs the phone
nearby. Navigation to an already-found store keeps working offline.

**"no internet"** — the phone is paired over Bluetooth, but the
request never reached the network: mobile data off, airplane mode, a
captive wifi portal, or the Garmin Connect app killed in the
background. Fix connectivity on the phone; the widget retries on its
own with a growing backoff.

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
  matches" (`limit=15` here) rather than an exhaustive enumeration
  like Overpass does — in an unusually dense cluster of matching
  results this could in theory miss the true nearest one, though in
  practice this hasn't been an issue for a single small area.
- Store addresses come from OSM `addressdetails`; stores with
  incomplete OSM data fall back to a generic "Zabka" label in the
  menu. Polish diacritics are folded to ASCII for font compatibility.
- **Two stores closer than 25 m to each other collapse into one
  menu entry.** That threshold exists to deduplicate the *same* shop
  coming back with slightly different OSM coordinates between
  refreshes, but it can't tell that apart from two genuinely distinct
  Zabkas in one building or on opposite sides of a mall entrance —
  so one of them is dropped. Fixing it properly means matching on
  OSM element identity (`osm_id`) instead of proximity, which the
  current GeoJSON parsing doesn't keep.
- No support for favorites.

## Privacy

See [PRIVACY.md](PRIVACY.md) — the short version: the only data that
ever leaves the watch is an approximate location sent to Nominatim to
find nearby stores; nothing is collected or stored by the app.

## License

This project is open source — see [LICENSE](LICENSE).
