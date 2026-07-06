import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// Main view of the widget: an arrow pointing towards the selected
// "Zabka" store plus the distance to it. All networking lives in
// NominatimClient, all math in GeoMath; this file only manages UI
// state, sensors and drawing.
class ZabkaFinderView extends WatchUi.View {

    // Below this distance the arrow/text switch to a "you're close"
    // color, the tip starts pulsing and a one-shot vibration fires.
    const CLOSE_DISTANCE_M = 30.0;
    // The vibration re-arms only after walking back out past this
    // distance (hysteresis), so GPS jitter around the 30 m line can't
    // retrigger it over and over.
    const VIBE_REARM_DISTANCE_M = 50.0;
    // How much of the remaining angle we close per redraw (0..1).
    // Lower = smoother/slower, higher = snappier but more jittery.
    const ANGLE_SMOOTHING = 0.25;
    // All pixel offsets below were originally tuned on the Venu 2
    // (416x416) and are now scaled by dc.getWidth()/REF_SIZE, so the
    // layout keeps its proportions on smaller screens (Fenix 7S =
    // 240x240, FR 255 = 260x260, ...).
    const REF_SIZE = 416.0f;
    // Background re-search: once the user has walked this far from
    // where the last successful search ran, the store list is stale
    // enough to silently refresh it.
    const RESEARCH_DISTANCE_M = 100.0;
    // ...but never re-search more often than this, as an extra layer
    // of Nominatim-policy politeness on top of the client's backoff
    // (still 30x above the 1 req/s public-instance limit).
    const RESEARCH_MIN_INTERVAL_MS = 30000;
    // Auto-retargeting treats two stores closer than this to each
    // other as the same store (GPS/OSM coordinate noise), so the
    // vibration latch isn't re-armed for a "new" target that's
    // actually the one we're already walking to.
    const TARGET_CHANGE_EPSILON_M = 2.0;
    // "Walking away" event for manually picked stores: fires once
    // the distance to the chosen store grows this much above the
    // minimum reached since it was picked (GPS noise won't produce
    // a 75 m monotonic drift).
    const AWAY_TRIGGER_DELTA_M = 75.0;
    // How long the prompt waits for a decision before automatically
    // switching to the nearest store.
    const AWAY_PROMPT_TIMEOUT_MS = 15000;
    // Above this ground speed the GPS course-over-ground replaces the
    // magnetic compass as the heading source. GPS course is immune to
    // compass miscalibration and wrist tilt, which in the field can
    // throw the compass off by 90-180 degrees; the compass takes over
    // again when standing (GPS course is meaningless when still).
    const GPS_HEADING_MIN_SPEED_MPS = 1.0;

    // --- State --------------------------------------------------------------

    private var logo;
    private var heading as Lang.Float = 0.0f;
    // True while heading comes from GPS course (walking); blocks the
    // noisier compass callback from overwriting it.
    private var gpsHeadingActive as Lang.Boolean = false;
    // Smoothed arrow angle actually used for drawing; eases towards
    // the target angle on every redraw instead of snapping.
    private var displayedAngle as Lang.Float = 0.0f;
    // User-facing status text, set from Rez.Strings (English default,
    // Polish via resources-pol) in initialize().
    private var status as Lang.String = "";

    // Localized strings, loaded once - status/prompt texts are used
    // on every redraw, so they shouldn't go through loadResource
    // each time.
    private var strSearchGps as Lang.String = "";
    private var strSearchStore as Lang.String = "";
    private var strNoStore as Lang.String = "";
    private var strErrTimeout as Lang.String = "";
    private var strErrPrefix as Lang.String = "";
    private var strAwayTitle as Lang.String = "";
    private var strAwayHint as Lang.String = "";
    private var distance as Lang.Float = 0.0f;
    private var zabkaBearing as Lang.Float = 0.0f;

    private var myLat as Lang.Double or Null = null;
    private var myLon as Lang.Double or Null = null;
    private var zabkaLat as Lang.Double or Null = null;
    private var zabkaLon as Lang.Double or Null = null;

    // All stores from the last successful search, each a Dictionary
    // {:lat, :lon, :addr}, sorted ascending by distance at receive time.
    private var stores as Lang.Array = [];

    // True while the store-selection Menu2 is on top of this view.
    // onHide() then keeps GPS/compass running, so the distance keeps
    // updating and there's no slow GPS re-acquisition after popping
    // back - onHide should only shut things down when the widget is
    // actually going away.
    private var menuOpen as Lang.Boolean = false;

    // One-shot latch for the proximity vibration (KROK 2): true once
    // we've vibrated for the current approach; re-armed by hysteresis
    // or by picking a new target from the menu.
    private var hasVibrated as Lang.Boolean = false;

    // True when the current target was explicitly picked from the
    // menu. Background re-searches then refresh the store list but
    // never silently retarget the arrow away from the user's choice.
    private var manualSelection as Lang.Boolean = false;

    // Where and when the last *successful* search ran, used to decide
    // when the user has moved far enough to warrant a re-search.
    private var lastSearchLat as Lang.Double or Null = null;
    private var lastSearchLon as Lang.Double or Null = null;
    private var lastSearchTimeMs as Lang.Number = 0;

    // --- "Walking away from manual target" event ---------------------------
    // Smallest distance to the manually picked store since it was
    // picked; the away-event triggers when the current distance
    // exceeds this baseline by AWAY_TRIGGER_DELTA_M.
    private var minManualDistance as Lang.Float = 1000000.0f;
    private var awayPromptActive as Lang.Boolean = false;
    private var awayPromptDeadlineMs as Lang.Number = 0;
    private var awayTimer as Timer.Timer or Null = null;

    private var client as NominatimClient;

    function initialize() {
        View.initialize();
        client = new NominatimClient(method(:onSearchResult));

        strSearchGps = WatchUi.loadResource(Rez.Strings.StatusSearchingGps) as Lang.String;
        strSearchStore = WatchUi.loadResource(Rez.Strings.StatusSearchingStore) as Lang.String;
        strNoStore = WatchUi.loadResource(Rez.Strings.StatusNoStore) as Lang.String;
        strErrTimeout = WatchUi.loadResource(Rez.Strings.ErrorTimeout) as Lang.String;
        strErrPrefix = WatchUi.loadResource(Rez.Strings.ErrorPrefix) as Lang.String;
        strAwayTitle = WatchUi.loadResource(Rez.Strings.AwayTitle) as Lang.String;
        strAwayHint = WatchUi.loadResource(Rez.Strings.AwayHint) as Lang.String;
        status = strSearchGps;
    }

    // Loads the logo bitmap once, when the layout is created.
    function onLayout(dc as Graphics.Dc) as Void {
        logo = WatchUi.loadResource(Rez.Drawables.LogoIcon);
    }

    // Called when the view becomes visible: start listening for
    // compass (sensor) events and GPS position updates.
    function onShow() as Void {
        menuOpen = false;
        Sensor.enableSensorEvents(method(:onSensorData));
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
    }

    // Called by the delegate right before pushing the store menu, so
    // onHide() knows not to tear down GPS/sensors.
    function setMenuOpen(open as Lang.Boolean) as Void {
        menuOpen = open;
    }

    // Called when the view is hidden: stop all sensor/GPS listeners
    // to save battery - unless we're only hidden behind the store
    // menu, in which case position updates must keep flowing.
    function onHide() as Void {
        if (menuOpen) {
            return;
        }
        client.stopWatchdog();
        stopAwayTimer();
        awayPromptActive = false;
        Sensor.enableSensorEvents(null);
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }

    // --- GPS / routing -------------------------------------------------------

    // Called every time a new GPS fix is available.
    function onPosition(info as Position.Info) as Void {
        var pos = info.position;
        if (pos == null) {
            return;
        }

        var loc = (pos as Position.Location).toDegrees();
        myLat = loc[0].toDouble();
        myLon = loc[1].toDouble();

        // While actually moving, trust the GPS course-over-ground
        // over the magnetic compass (see GPS_HEADING_MIN_SPEED_MPS).
        var spd = info.speed;
        if (spd != null && spd >= GPS_HEADING_MIN_SPEED_MPS && info.heading != null) {
            heading = info.heading as Lang.Float;
            gpsHeadingActive = true;
        } else {
            gpsHeadingActive = false;
        }

        if (zabkaLat == null) {
            // No target yet: request one, respecting the client's
            // retry backoff so we don't hammer the API on every fix.
            if (client.shouldRequest()) {
                status = strSearchStore;
                client.search(myLat as Lang.Double, myLon as Lang.Double);
            }
        } else {
            // Target known: refresh distance/bearing as the user
            // moves, and consider a silent background re-search.
            calculateRouting();
            status = distance.format("%.0f") + " m";
            maybeResearch();
        }

        WatchUi.requestUpdate();
    }

    // Silently refreshes the store list once the user has walked far
    // enough from where the last search ran - so the widget notices
    // when a *different* store has become the nearest one. No status
    // change: the arrow keeps guiding uninterrupted while the request
    // is in flight. Public: also nudged by the delegate whenever the
    // store menu is opened.
    function maybeResearch() as Void {
        if (myLat == null || !client.shouldRequest()) {
            return;
        }
        if (System.getTimer() - lastSearchTimeMs < RESEARCH_MIN_INTERVAL_MS) {
            return;
        }
        if (lastSearchLat != null) {
            var moved = GeoMath.haversineDistance(
                lastSearchLat as Lang.Double, lastSearchLon as Lang.Double,
                myLat as Lang.Double, myLon as Lang.Double);
            if (moved < RESEARCH_DISTANCE_M) {
                return;
            }
            System.println("Zabka re-search: moved " + moved.format("%.0f") + " m");
        }
        client.search(myLat as Lang.Double, myLon as Lang.Double);
    }

    // Callback from NominatimClient with parsed [lat, lon] pairs (or
    // null on failure). Filters to the true circular search radius,
    // sorts ascending by distance and locks onto the nearest store.
    function onSearchResult(responseCode as Lang.Number, coords as Lang.Array or Null) as Void {
        var hadTarget = (zabkaLat != null);

        if (responseCode == 200 && coords != null) {
            lastSearchLat = myLat;
            lastSearchLon = myLon;
            lastSearchTimeMs = System.getTimer();

            var fresh = buildSortedStores(coords);
            System.println("Zabka result: " + coords.size() + " raw, "
                + fresh.size() + " in range, " + stores.size() + " known");

            if (fresh.size() > 0) {
                client.registerSuccess();
            } else {
                client.registerNoResult();
            }

            // Merge instead of replace: previously known stores that
            // are still within range survive a refresh that didn't
            // re-find them (Nominatim's relevance ranking can drop
            // results between calls), so the menu only ever *gains*
            // knowledge as you walk.
            stores = mergeStores(fresh);

            if (stores.size() > 0) {
                sortStoresByCurrentDistance();
                var nearest = stores[0] as Lang.Dictionary;
                var nLat = nearest[:lat] as Lang.Double;
                var nLon = nearest[:lon] as Lang.Double;

                if (!hadTarget) {
                    // First lock: take the nearest automatically.
                    manualSelection = false;
                    setTarget(nLat, nLon);
                } else if (!manualSelection) {
                    // Background refresh in auto mode: follow the
                    // nearest store, but only retarget when it's
                    // actually a different one - otherwise the
                    // vibration latch would re-arm for the same store.
                    var shift = GeoMath.haversineDistance(
                        zabkaLat as Lang.Double, zabkaLon as Lang.Double, nLat, nLon);
                    if (shift > TARGET_CHANGE_EPSILON_M) {
                        setTarget(nLat, nLon);
                    }
                }
                // Manual selection: keep the user's choice, the
                // refreshed list just shows up next time in the menu.
                status = distance.format("%.0f") + " m";
            } else if (!hadTarget) {
                // Nothing known at all yet.
                status = strNoStore;
            }
        } else if (!hadTarget) {
            // Errors only surface while we have nothing to guide to;
            // during background refreshes they stay silent (the
            // client's backoff already schedules the retry).
            if (responseCode == client.TIMEOUT_RESPONSE_CODE) {
                status = strErrTimeout;
            } else {
                status = strErrPrefix + responseCode;
            }
        }

        WatchUi.requestUpdate();
    }

    // Filters raw store entries down to SEARCH_RADIUS_M around the
    // current position and returns them as {:lat, :lon, :addr}
    // dictionaries sorted ascending by Haversine distance (insertion
    // sort - at most 20 entries, so O(n^2) is irrelevant here).
    private function buildSortedStores(coords as Lang.Array) as Lang.Array {
        var lat = myLat as Lang.Double;
        var lon = myLon as Lang.Double;

        var list = [] as Lang.Array;
        var dists = [] as Lang.Array;

        for (var i = 0; i < coords.size(); i++) {
            var entry = coords[i] as Lang.Dictionary;
            var candLat = entry[:lat] as Lang.Double;
            var candLon = entry[:lon] as Lang.Double;
            var d = GeoMath.haversineDistance(lat, lon, candLat, candLon);
            if (d > client.SEARCH_RADIUS_M) {
                continue;
            }

            // Insert keeping both arrays sorted ascending by distance.
            var pos = 0;
            while (pos < dists.size() && (dists[pos] as Lang.Double) <= d) {
                pos += 1;
            }
            dists.add(0.0d);
            list.add(null);
            for (var j = dists.size() - 1; j > pos; j--) {
                dists[j] = dists[j - 1];
                list[j] = list[j - 1];
            }
            dists[pos] = d;
            list[pos] = { :lat => candLat, :lon => candLon, :addr => entry[:addr] };
        }
        return list;
    }

    // Combines fresh search results with previously known stores:
    // old entries survive if they're still within SEARCH_RADIUS_M of
    // the current position and aren't within 25 m of a fresh entry
    // (that close = the same store, possibly with slightly different
    // OSM coordinates). Fresh data wins on duplicates.
    private function mergeStores(fresh as Lang.Array) as Lang.Array {
        var lat = myLat as Lang.Double;
        var lon = myLon as Lang.Double;

        for (var i = 0; i < stores.size(); i++) {
            var old = stores[i] as Lang.Dictionary;
            var oLat = old[:lat] as Lang.Double;
            var oLon = old[:lon] as Lang.Double;

            if (GeoMath.haversineDistance(lat, lon, oLat, oLon) > client.SEARCH_RADIUS_M) {
                continue;
            }
            var duplicate = false;
            for (var j = 0; j < fresh.size(); j++) {
                var f = fresh[j] as Lang.Dictionary;
                if (GeoMath.haversineDistance(oLat, oLon,
                        f[:lat] as Lang.Double, f[:lon] as Lang.Double) < 25.0) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                fresh.add(old);
            }
        }
        return fresh;
    }

    // Re-sorts the full store list by distance from the *current*
    // position, storing the fresh distance in each entry's :dist.
    // The order from search time goes stale as the user moves, and
    // it must be re-established on the `stores` array itself (not
    // just on a copy) because menu item ids are indices into it.
    private function sortStoresByCurrentDistance() as Void {
        var lat = myLat as Lang.Double;
        var lon = myLon as Lang.Double;

        var sorted = [] as Lang.Array;
        for (var i = 0; i < stores.size(); i++) {
            var s = stores[i] as Lang.Dictionary;
            var d = GeoMath.haversineDistance(lat, lon, s[:lat] as Lang.Double, s[:lon] as Lang.Double);
            s[:dist] = d;

            var pos = 0;
            while (pos < sorted.size()
                   && ((sorted[pos] as Lang.Dictionary)[:dist] as Lang.Double) <= d) {
                pos += 1;
            }
            sorted.add(null);
            for (var j = sorted.size() - 1; j > pos; j--) {
                sorted[j] = sorted[j - 1];
            }
            sorted[pos] = s;
        }
        stores = sorted;
    }

    // Returns up to `max` stores as dictionaries {:lat, :lon, :addr,
    // :dist} for the selection menu (KROK 4), freshly re-sorted by
    // distance from the current position.
    function getNearestStores(max as Lang.Number) as Lang.Array {
        var result = [] as Lang.Array;
        if (myLat == null) {
            return result;
        }
        sortStoresByCurrentDistance();
        var count = stores.size() < max ? stores.size() : max;
        for (var i = 0; i < count; i++) {
            var s = stores[i] as Lang.Dictionary;
            result.add({ :lat => s[:lat], :lon => s[:lon], :addr => s[:addr], :dist => s[:dist] });
        }
        return result;
    }

    // Called by the menu delegate when the user picks a store from
    // the Menu2 list: retargets the arrow and re-arms the vibration.
    function selectStore(index as Lang.Number) as Void {
        if (index < 0 || index >= stores.size()) {
            return;
        }
        var s = stores[index] as Lang.Dictionary;
        // An explicit pick from the menu: background re-searches must
        // not silently override it.
        manualSelection = true;
        // Defensive: a pick always ends any pending away-prompt, and
        // the baseline must start fresh ABOVE any plausible distance
        // so calculateRouting() immediately lowers it to the real one.
        stopAwayTimer();
        awayPromptActive = false;
        minManualDistance = 1000000.0f;
        setTarget(s[:lat] as Lang.Double, s[:lon] as Lang.Double);
        status = distance.format("%.0f") + " m";
        WatchUi.requestUpdate();
    }

    // Sets a new navigation target and resets the one-shot vibration
    // latch so approaching the *new* store vibrates again.
    private function setTarget(lat as Lang.Double, lon as Lang.Double) as Void {
        zabkaLat = lat;
        zabkaLon = lon;
        hasVibrated = false;
        calculateRouting();
    }

    // Computes the distance and initial compass bearing from the
    // user's position to the target store, then runs the proximity
    // (vibration) check on the fresh distance.
    function calculateRouting() as Void {
        if (myLat == null || zabkaLat == null) {
            return;
        }
        var lat1 = myLat as Lang.Double;
        var lon1 = myLon as Lang.Double;
        var lat2 = zabkaLat as Lang.Double;
        var lon2 = zabkaLon as Lang.Double;

        distance = GeoMath.haversineDistance(lat1, lon1, lat2, lon2).toFloat();
        zabkaBearing = GeoMath.initialBearing(lat1, lon1, lat2, lon2);

        checkProximityAlert();
        checkWalkingAway();
    }

    // Fires the "walking away" prompt when the user drifts
    // AWAY_TRIGGER_DELTA_M above the closest they've been to their
    // manually picked store. GPS-driven (calculateRouting), so it
    // can't spam from compass redraws.
    private function checkWalkingAway() as Void {
        if (!manualSelection || awayPromptActive || menuOpen) {
            return;
        }
        if (distance < minManualDistance) {
            minManualDistance = distance;
        } else if (distance > minManualDistance + AWAY_TRIGGER_DELTA_M) {
            startAwayPrompt();
        }
    }

    private function startAwayPrompt() as Void {
        awayPromptActive = true;
        awayPromptDeadlineMs = System.getTimer() + AWAY_PROMPT_TIMEOUT_MS;
        vibrateShort();
        awayTimer = new Timer.Timer();
        (awayTimer as Timer.Timer).start(method(:onAwayTimeout), AWAY_PROMPT_TIMEOUT_MS, false);
        WatchUi.requestUpdate();
    }

    private function stopAwayTimer() as Void {
        if (awayTimer != null) {
            (awayTimer as Timer.Timer).stop();
            awayTimer = null;
        }
    }

    function isAwayPromptActive() as Lang.Boolean {
        return awayPromptActive;
    }

    // User chose (tap/START, or went to the menu) to stay with the
    // manual target: end the event with a vibration and reset the
    // baseline so walking away *again* re-triggers it later.
    function dismissAwayPrompt() as Void {
        if (!awayPromptActive) {
            return;
        }
        stopAwayTimer();
        awayPromptActive = false;
        minManualDistance = distance;
        vibrateShort();
        WatchUi.requestUpdate();
    }

    // No decision within 15 s: automatically retarget to whatever
    // store is nearest now, with a closing vibration.
    function onAwayTimeout() as Void {
        awayTimer = null;
        if (!awayPromptActive) {
            return;
        }
        awayPromptActive = false;

        if (stores.size() > 0 && myLat != null) {
            sortStoresByCurrentDistance();
            var nearest = stores[0] as Lang.Dictionary;
            manualSelection = false;
            setTarget(nearest[:lat] as Lang.Double, nearest[:lon] as Lang.Double);
            status = distance.format("%.0f") + " m";
        }
        // Even with an empty store list the event must end audibly.
        vibrateShort();
        WatchUi.requestUpdate();
    }

    // KROK 2: one-shot haptic feedback on entering the 30 m zone.
    // Lives in the routing logic (driven by GPS fixes), NOT in
    // onUpdate(), which redraws on every compass event - so it can
    // never fire once per frame. The hasVibrated latch plus the
    // re-arm hysteresis guarantee exactly one buzz per approach.
    private function checkProximityAlert() as Void {
        if (distance <= CLOSE_DISTANCE_M) {
            if (!hasVibrated) {
                hasVibrated = true;
                vibrateShort();
            }
        } else if (distance > VIBE_REARM_DISTANCE_M) {
            // Walked back out well past the zone: re-arm.
            hasVibrated = false;
        }
    }

    // Short, distinct double pulse. Guarded with `has :vibrate`, as
    // Attention.vibrate isn't available on every device (and can be
    // disabled system-wide by the user).
    private function vibrateShort() as Void {
        if (Attention has :vibrate) {
            var pattern = [
                new Attention.VibeProfile(75, 250),  // 75% strength, 250 ms
                new Attention.VibeProfile(0, 100),   // pause
                new Attention.VibeProfile(75, 250)
            ] as Lang.Array<Attention.VibeProfile>;
            Attention.vibrate(pattern);
        }
    }

    // --- Compass -------------------------------------------------------------

    // Called whenever a new compass heading is available. The compass
    // only drives the arrow while standing still - when walking, the
    // GPS course set in onPosition() wins (it's far more reliable in
    // the field).
    function onSensorData(sensorInfo as Sensor.Info) as Void {
        if (!gpsHeadingActive && sensorInfo.heading != null) {
            heading = sensorInfo.heading as Lang.Float;
        }
        // Redraw either way: the smoothed arrow keeps easing towards
        // the target angle between heading changes.
        WatchUi.requestUpdate();
    }

    // --- Drawing -------------------------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var cy = dc.getHeight() / 2.0;
        var s = dc.getWidth() / REF_SIZE;

        if (logo != null && !awayPromptActive) {
            // The bitmap itself is already the right size for this
            // screen: variants/ folders override LogoIcon with a
            // pre-scaled bitmap per device class (better quality
            // than runtime scaling, and works on every CIQ level).
            dc.drawBitmap(cx - (logo.getWidth() / 2.0), 20 * s, logo);
        }

        drawArrow(dc, cx, cy, s);
        drawStatus(dc, cx, cy, s);

        if (awayPromptActive) {
            // Drawn where the logo normally sits, so nothing overlaps.
            drawAwayPrompt(dc, cx, s);
        }
    }

    // The "walking away from your chosen store" prompt: red header
    // with a live countdown plus a hint line. The arrow and distance
    // stay visible underneath - the widget keeps guiding to the
    // manual target until the user (or the timeout) decides.
    function drawAwayPrompt(dc as Graphics.Dc, cx as Lang.Float, s as Lang.Float) as Void {
        var remainingS = (awayPromptDeadlineMs - System.getTimer()) / 1000;
        if (remainingS < 0) {
            remainingS = 0;
        }

        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 24 * s, Graphics.FONT_SMALL,
                    strAwayTitle + remainingS + "s", Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 62 * s, Graphics.FONT_XTINY,
                    strAwayHint, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Color used for both the arrow and the distance readout: gray
    // while searching, orange once found, bright green once close.
    function currentAccentColor() as Graphics.ColorType {
        if (zabkaLat == null) {
            return Graphics.COLOR_LT_GRAY;
        }
        if (distance <= CLOSE_DISTANCE_M) {
            return Graphics.COLOR_GREEN;
        }
        return Graphics.COLOR_ORANGE;
    }

    // Draws the direction arrow, smoothly easing towards the target
    // angle each redraw, with a dark outline for contrast and a
    // pulsing dot at the tip once we're close to the store.
    function drawArrow(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float, s as Lang.Float) as Void {
        var targetAngle = 0.0f;
        if (zabkaLat != null) {
            targetAngle = GeoMath.normalizeAngle(zabkaBearing - heading);
        }

        // Ease the displayed angle towards the target via the
        // shortest angular path - removes most compass jitter.
        var diff = GeoMath.normalizeAngle(targetAngle - displayedAngle);
        displayedAngle = GeoMath.normalizeAngle(displayedAngle + diff * ANGLE_SMOOTHING);

        var cosA = Math.cos(displayedAngle);
        var sinA = Math.sin(displayedAngle);

        // Base arrow shape (pointing "up"), rotated below and scaled
        // to the screen size.
        var arrowPoints = [[0, -40 * s], [20 * s, 30 * s], [0, 15 * s], [-20 * s, 30 * s]];
        // Slightly larger copy drawn first in a dark color, so it
        // reads as a thin outline around the colored arrow on top.
        var outlineScale = 1.25;

        var arrowScreen = new [4];
        var outlineScreen = new [4];

        for (var i = 0; i < 4; i++) {
            var px = arrowPoints[i][0];
            var py = arrowPoints[i][1];

            // Standard 2D rotation matrix around the screen center.
            var rx = (px * cosA) - (py * sinA);
            var ry = (px * sinA) + (py * cosA);
            arrowScreen[i] = [cx + rx, cy + ry];

            var orx = (px * outlineScale * cosA) - (py * outlineScale * sinA);
            var ory = (px * outlineScale * sinA) + (py * outlineScale * cosA);
            outlineScreen[i] = [cx + orx, cy + ory];
        }

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(outlineScreen);

        dc.setColor(currentAccentColor(), Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(arrowScreen);

        if (zabkaLat != null && distance <= CLOSE_DISTANCE_M) {
            drawCloseIndicator(dc, cx, cy, displayedAngle, s);
        }
    }

    // Small pulsing dot just beyond the tip of the arrow, shown once
    // the user is within CLOSE_DISTANCE_M of the store.
    function drawCloseIndicator(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float, angle as Lang.Float, s as Lang.Float) as Void {
        // Same rotation formula as the (scaled) arrow tip point.
        var tipX = cx + (40 * s * Math.sin(angle));
        var tipY = cy - (40 * s * Math.cos(angle));

        // Pulse the radius over time using a sine wave driven by the
        // system clock - no extra timer needed, since onUpdate
        // already runs frequently from compass events.
        var phase = System.getTimer() / 250.0;
        var pulse = (3 + 2 * Math.sin(phase)) * s;
        if (pulse < 2) {
            pulse = 2;
        }

        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(tipX, tipY, pulse);
    }

    // Draws the status text: the distance in a large colored font
    // once known, or a smaller plain message otherwise.
    function drawStatus(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float, s as Lang.Float) as Void {
        // System fonts don't scale with the screen, so on small
        // displays (Fenix 7S/FR 255 etc.) drop one font size down or
        // the text overflows the round screen edges.
        var small = dc.getWidth() < 300;
        var font = small ? Graphics.FONT_SMALL : Graphics.FONT_MEDIUM;
        var color = Graphics.COLOR_WHITE;

        if (zabkaLat != null) {
            // NOT a FONT_NUMBER_* font: those only contain digit
            // glyphs, and status includes a trailing " m" suffix.
            font = small ? Graphics.FONT_MEDIUM : Graphics.FONT_LARGE;
            color = currentAccentColor();
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 80 * s, font, status, Graphics.TEXT_JUSTIFY_CENTER);
    }
}
