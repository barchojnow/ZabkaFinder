import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Sensor;
import Toybox.System;
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

    // --- State --------------------------------------------------------------

    private var logo;
    private var heading as Lang.Float = 0.0f;
    // Smoothed arrow angle actually used for drawing; eases towards
    // the target angle on every redraw instead of snapping.
    private var displayedAngle as Lang.Float = 0.0f;
    // User-facing status text. Kept in Polish, without diacritics
    // (for font compatibility), on purpose.
    private var status as Lang.String = "szukam gps...";
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

    private var client as NominatimClient;

    function initialize() {
        View.initialize();
        client = new NominatimClient(method(:onSearchResult));
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

        if (zabkaLat == null) {
            // No target yet: request one, respecting the client's
            // retry backoff so we don't hammer the API on every fix.
            if (client.shouldRequest()) {
                status = "szukam zabki...";
                client.search(myLat as Lang.Double, myLon as Lang.Double);
            }
        } else {
            // Target known: refresh distance/bearing as the user moves.
            calculateRouting();
            status = distance.format("%.0f") + " m";
        }

        WatchUi.requestUpdate();
    }

    // Callback from NominatimClient with parsed [lat, lon] pairs (or
    // null on failure). Filters to the true circular search radius,
    // sorts ascending by distance and locks onto the nearest store.
    function onSearchResult(responseCode as Lang.Number, coords as Lang.Array or Null) as Void {
        if (responseCode == 200 && coords != null) {
            stores = buildSortedStores(coords);

            if (stores.size() > 0) {
                client.registerSuccess();
                var nearest = stores[0] as Lang.Dictionary;
                setTarget(nearest[:lat] as Lang.Double, nearest[:lon] as Lang.Double);
                status = distance.format("%.0f") + " m";
            } else {
                client.registerNoResult();
                status = "brak zabki w poblizu";
            }
        } else if (responseCode == client.TIMEOUT_RESPONSE_CODE) {
            status = "blad: timeout";
        } else {
            status = "blad: " + responseCode;
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

    // Returns up to `max` stores as dictionaries {:lat, :lon, :addr,
    // :dist}, with :dist recomputed against the *current* position,
    // for the selection menu (KROK 4).
    function getNearestStores(max as Lang.Number) as Lang.Array {
        var result = [] as Lang.Array;
        if (myLat == null) {
            return result;
        }
        var count = stores.size() < max ? stores.size() : max;
        for (var i = 0; i < count; i++) {
            var s = stores[i] as Lang.Dictionary;
            var d = GeoMath.haversineDistance(myLat as Lang.Double, myLon as Lang.Double,
                                              s[:lat] as Lang.Double, s[:lon] as Lang.Double);
            result.add({ :lat => s[:lat], :lon => s[:lon], :addr => s[:addr], :dist => d });
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

    // Called whenever a new compass heading is available.
    function onSensorData(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.heading != null) {
            heading = sensorInfo.heading as Lang.Float;
            WatchUi.requestUpdate();
        }
    }

    // --- Drawing -------------------------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var cy = dc.getHeight() / 2.0;

        if (logo != null) {
            dc.drawBitmap(cx - (logo.getWidth() / 2.0), 20, logo);
        }

        drawArrow(dc, cx, cy);
        drawStatus(dc, cx, cy);
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
    function drawArrow(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float) as Void {
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

        // Base arrow shape (pointing "up"), rotated below.
        var arrowPoints = [[0, -40], [20, 30], [0, 15], [-20, 30]];
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
            drawCloseIndicator(dc, cx, cy, displayedAngle);
        }
    }

    // Small pulsing dot just beyond the tip of the arrow, shown once
    // the user is within CLOSE_DISTANCE_M of the store.
    function drawCloseIndicator(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float, angle as Lang.Float) as Void {
        // Same rotation formula as the arrow tip point [0, -40].
        var tipX = cx + (40 * Math.sin(angle));
        var tipY = cy - (40 * Math.cos(angle));

        // Pulse the radius over time using a sine wave driven by the
        // system clock - no extra timer needed, since onUpdate
        // already runs frequently from compass events.
        var phase = System.getTimer() / 250.0;
        var pulse = 3 + 2 * Math.sin(phase);

        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(tipX, tipY, pulse);
    }

    // Draws the status text: the distance in a large colored font
    // once known, or a smaller plain message otherwise.
    function drawStatus(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float) as Void {
        var font = Graphics.FONT_MEDIUM;
        var color = Graphics.COLOR_WHITE;

        if (zabkaLat != null) {
            // NOT a FONT_NUMBER_* font: those only contain digit
            // glyphs, and status includes a trailing " m" suffix.
            font = Graphics.FONT_LARGE;
            color = currentAccentColor();
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 80, font, status, Graphics.TEXT_JUSTIFY_CENTER);
    }
}
