import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;
import Toybox.WatchUi;

// Main view of the widget: an arrow pointing towards the selected
// "Zabka" store plus the distance to it. This file owns the widget
// lifecycle, GPS/compass handling and drawing; everything else lives
// in focused collaborators:
//   NominatimClient  - networking, watchdog, retry backoff
//   StoreList        - store collection, filtering/merging/sorting
//   ProximityAlerts  - arrival vibration + walking-away prompt logic
//   GeoMath          - distance/bearing/angle math
//   TextFit          - round-screen adaptive font sizing
class ZabkaFinderView extends WatchUi.View {

    // How much of the remaining angle we close per redraw (0..1).
    // Lower = smoother/slower, higher = snappier but more jittery.
    const ANGLE_SMOOTHING = 0.25;
    // All pixel offsets below were originally tuned on the Venu 2
    // (416x416) and are scaled by dc.getWidth()/REF_SIZE, so the
    // layout keeps its proportions on every screen size.
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
    private var strNoPhone as Lang.String = "";
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

    // True while the store-selection Menu2 is on top of this view.
    // onHide() then keeps GPS/compass running, so the distance keeps
    // updating and there's no slow GPS re-acquisition after popping
    // back - onHide should only shut things down when the widget is
    // actually going away.
    private var menuOpen as Lang.Boolean = false;

    // True when the current target was explicitly picked from the
    // menu. Background re-searches then refresh the store list but
    // never silently retarget the arrow away from the user's choice.
    private var manualSelection as Lang.Boolean = false;

    // Where and when the last *successful* search ran, used to decide
    // when the user has moved far enough to warrant a re-search.
    private var lastSearchLat as Lang.Double or Null = null;
    private var lastSearchLon as Lang.Double or Null = null;
    private var lastSearchTimeMs as Lang.Number = 0;

    private var client as NominatimClient;
    private var storeList as StoreList;
    private var alerts as ProximityAlerts;

    function initialize() {
        View.initialize();
        client = new NominatimClient(method(:onSearchResult));
        storeList = new StoreList();
        alerts = new ProximityAlerts(method(:onAwayAutoSwitch));

        strSearchGps = WatchUi.loadResource(Rez.Strings.StatusSearchingGps) as Lang.String;
        strSearchStore = WatchUi.loadResource(Rez.Strings.StatusSearchingStore) as Lang.String;
        strNoStore = WatchUi.loadResource(Rez.Strings.StatusNoStore) as Lang.String;
        strNoPhone = WatchUi.loadResource(Rez.Strings.StatusNoPhone) as Lang.String;
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
        startPositioning();
    }

    // Requests the best positioning configuration the device offers.
    // Multi-GNSS (GPS+GLONASS+Galileo+BeiDou) and SatIQ acquire a fix
    // noticeably faster than plain GPS, especially on a cold start -
    // but configuration support only exists on newer devices, so
    // everything is `has`-guarded with a plain-GPS fallback.
    private function startPositioning() as Void {
        if (Position has :hasConfigurationSupport) {
            // SatIQ: the watch auto-picks the best constellation mix.
            if (Position has :CONFIGURATION_SAT_IQ
                && Position.hasConfigurationSupport(Position.CONFIGURATION_SAT_IQ)) {
                Position.enableLocationEvents({
                    :acquisitionType => Position.LOCATION_CONTINUOUS,
                    :configuration => Position.CONFIGURATION_SAT_IQ
                }, method(:onPosition));
                return;
            }
            if (Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1
                && Position.hasConfigurationSupport(Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1)) {
                Position.enableLocationEvents({
                    :acquisitionType => Position.LOCATION_CONTINUOUS,
                    :configuration => Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1
                }, method(:onPosition));
                return;
            }
        }
        // Older devices: plain GPS, exactly as before.
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
        alerts.reset();
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
            // HTTP requests go through the paired phone, so without
            // a phone connection the request is doomed to fail with
            // -104 (BLE_CONNECTION_UNAVAILABLE) - tell the user what
            // to fix instead of firing it. Position events keep
            // coming, so this re-checks automatically after
            // reconnecting.
            if (!System.getDeviceSettings().phoneConnected) {
                status = strNoPhone;
            } else if (client.shouldRequest()) {
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
        // Background refreshes silently wait for the phone to come
        // back instead of burning retries on guaranteed -104s.
        if (!System.getDeviceSettings().phoneConnected) {
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

    // Callback from NominatimClient with parsed store entries (or
    // null on failure). Updates the store list and target selection.
    function onSearchResult(responseCode as Lang.Number, coords as Lang.Array or Null) as Void {
        var hadTarget = (zabkaLat != null);

        if (responseCode == 200 && coords != null) {
            lastSearchLat = myLat;
            lastSearchLon = myLon;
            lastSearchTimeMs = System.getTimer();

            var freshCount = storeList.update(coords, myLat as Lang.Double,
                myLon as Lang.Double, client.SEARCH_RADIUS_M);
            System.println("Zabka result: " + coords.size() + " raw, "
                + freshCount + " in range, " + storeList.size() + " known");

            if (freshCount > 0) {
                client.registerSuccess();
            } else {
                client.registerNoResult();
            }

            if (storeList.size() > 0) {
                storeList.sortByDistance(myLat as Lang.Double, myLon as Lang.Double);
                var nearest = storeList.nearest() as Lang.Dictionary;
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
            if (responseCode == Communications.BLE_CONNECTION_UNAVAILABLE) {
                // Phone dropped between the connectivity check and
                // the request itself.
                status = strNoPhone;
            } else if (responseCode == client.TIMEOUT_RESPONSE_CODE) {
                status = strErrTimeout;
            } else {
                status = strErrPrefix + responseCode;
            }
        }

        WatchUi.requestUpdate();
    }

    // Returns up to `max` stores for the selection menu.
    function getNearestStores(max as Lang.Number) as Lang.Array {
        if (myLat == null) {
            return [] as Lang.Array;
        }
        return storeList.getNearest(max, myLat as Lang.Double, myLon as Lang.Double);
    }

    // Called by the menu delegate when the user picks a store from
    // the Menu2 list: retargets the arrow and re-arms the alerts.
    function selectStore(index as Lang.Number) as Void {
        var s = storeList.get(index);
        if (s == null) {
            return;
        }
        // An explicit pick from the menu: background re-searches must
        // not silently override it, and any pending away-prompt ends.
        manualSelection = true;
        alerts.onManualPick();
        setTarget(s[:lat] as Lang.Double, s[:lon] as Lang.Double);
        status = distance.format("%.0f") + " m";
        WatchUi.requestUpdate();
    }

    // Sets a new navigation target and re-arms the arrival vibration
    // so approaching the *new* store vibrates again.
    private function setTarget(lat as Lang.Double, lon as Lang.Double) as Void {
        zabkaLat = lat;
        zabkaLon = lon;
        alerts.onNewTarget();
        calculateRouting();
    }

    // Computes the distance and initial compass bearing from the
    // user's position to the target store, then feeds the fresh
    // distance to the haptic alert state machines.
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

        alerts.onDistanceUpdated(distance, manualSelection, menuOpen);
    }

    // --- Away-prompt bridge (state lives in ProximityAlerts) ---------------

    function isAwayPromptActive() as Lang.Boolean {
        return alerts.isAwayActive();
    }

    // Tap/START during the prompt: keep the user's chosen store.
    function dismissAwayPrompt() as Void {
        alerts.dismissAway(distance);
        WatchUi.requestUpdate();
    }

    // Prompt timed out: automatically retarget to whatever store is
    // nearest now (the closing vibration already happened in alerts).
    function onAwayAutoSwitch() as Void {
        if (storeList.size() > 0 && myLat != null) {
            storeList.sortByDistance(myLat as Lang.Double, myLon as Lang.Double);
            var nearest = storeList.nearest() as Lang.Dictionary;
            manualSelection = false;
            setTarget(nearest[:lat] as Lang.Double, nearest[:lon] as Lang.Double);
            status = distance.format("%.0f") + " m";
        }
        WatchUi.requestUpdate();
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

        var awayActive = alerts.isAwayActive();

        if (logo != null && !awayActive) {
            // The bitmap itself is already the right size for this
            // screen: variants/ folders override LogoIcon with a
            // pre-scaled bitmap per device class (better quality
            // than runtime scaling, and works on every CIQ level).
            dc.drawBitmap(cx - (logo.getWidth() / 2.0), 20 * s, logo);
        }

        drawArrow(dc, cx, cy, s);
        drawStatus(dc, cx, cy, s);

        if (awayActive) {
            // Drawn where the logo normally sits, so nothing overlaps.
            drawAwayPrompt(dc, cx, s);
        }
    }

    // The "walking away from your chosen store" prompt: red header
    // with a live countdown plus a hint line. The arrow and distance
    // stay visible underneath - the widget keeps guiding to the
    // manual target until the user (or the timeout) decides.
    function drawAwayPrompt(dc as Graphics.Dc, cx as Lang.Float, s as Lang.Float) as Void {
        // Round screens are narrow near the top, so the prompt sits
        // lower than the logo it replaces, and both lines auto-fit
        // to the screen chord at their position.
        var titleText = strAwayTitle + alerts.awayRemainingSeconds() + "s";
        var titleY = 52 * s;
        var titleFont = TextFit.fitFont(dc, titleText, 2, titleY, true); // start at FONT_SMALL

        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, titleY, titleFont, titleText, Graphics.TEXT_JUSTIFY_CENTER);

        var hintY = 92 * s;
        var hintFont = TextFit.fitFont(dc, strAwayHint, 4, hintY, true); // XTINY, fit-checked

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, hintY, hintFont, strAwayHint, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Color used for both the arrow and the distance readout: gray
    // while searching, orange once found, bright green once close.
    function currentAccentColor() as Graphics.ColorType {
        if (zabkaLat == null) {
            return Graphics.COLOR_LT_GRAY;
        }
        if (distance <= alerts.CLOSE_DISTANCE_M) {
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

        if (zabkaLat != null && distance <= alerts.CLOSE_DISTANCE_M) {
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
    // once known, or a smaller plain message otherwise. The font
    // shrinks automatically until the text fits the screen chord.
    function drawStatus(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float, s as Lang.Float) as Void {
        // NOT a FONT_NUMBER_* font for the distance: those only have
        // digit glyphs, and status includes a trailing " m" suffix.
        var startIdx = 1; // FONT_MEDIUM for plain messages
        var color = Graphics.COLOR_WHITE;
        if (zabkaLat != null) {
            startIdx = 0; // FONT_LARGE for the distance readout
            color = currentAccentColor();
        }

        var yTop = cy + 80 * s;
        var font = TextFit.fitFont(dc, status, startIdx, yTop, false);

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yTop, font, status, Graphics.TEXT_JUSTIFY_CENTER);
    }
}
