import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Sensor;
import Toybox.Math;
import Toybox.Position;
import Toybox.Communications;
import Toybox.System;
import Toybox.Timer;
import Toybox.Lang;

// Main (and only) view of the widget.
// Shows an arrow pointing towards the nearest "Zabka" store (a Polish
// convenience store chain) together with the distance to it.
class ZabkaFinderView extends WatchUi.View {

    // --- Tunable constants ------------------------------------------------

    // Mean Earth radius in meters, used by the Haversine formula.
    const EARTH_RADIUS_M = 6371000.0;
    // Overpass search radius, in meters, around the current position.
    const SEARCH_RADIUS_M = 500;
    // Below this distance the arrow/text switch to a "you're close"
    // color and the tip starts pulsing.
    const CLOSE_DISTANCE_M = 30.0;
    // How much of the remaining angle we close per redraw (0..1).
    // Lower = smoother/slower, higher = snappier but more jittery.
    const ANGLE_SMOOTHING = 0.25;
    // Backoff for retries after a failed (non-200 / network error)
    // Overpass request. The delay grows with each consecutive
    // failure, capped at RETRY_MAX_DELAY_MS.
    const RETRY_BASE_DELAY_MS = 5000;
    const RETRY_MAX_DELAY_MS = 30000;
    // How long to wait before re-checking after a *successful*
    // request that legitimately found no store nearby (not a
    // failure - the user may simply need to keep walking).
    const NO_RESULT_RETRY_DELAY_MS = 10000;
    // Hard ceiling on how long we wait for a single Overpass request
    // before giving up on it entirely, even if makeWebRequest's own
    // callback never fires (observed in practice: a slow/overloaded
    // mirror can apparently hang far longer than any reasonable UX
    // should tolerate). This is a client-side safety net independent
    // of whatever the network layer is doing.
    const REQUEST_TIMEOUT_MS = 25000;

    // Public Overpass instances can be temperamental (outages, rate
    // limits, anti-bot filtering that misfires on legitimate
    // clients - overpass-api.de is known to return HTTP 406 for many
    // clients as of mid-2026). Rotating through a few known-good
    // mirrors on failure makes the widget noticeably more resilient
    // than hammering a single endpoint.
    const OVERPASS_ENDPOINTS = [
        "https://overpass.osm.jp/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass-api.de/api/interpreter"
    ];

    // --- State --------------------------------------------------------------

    private var logo;
    private var heading as Lang.Float = 0.0f;
    // Smoothed arrow angle actually used for drawing; eases towards
    // the target angle on every redraw instead of snapping, to avoid
    // a jittery/twitchy arrow caused by noisy compass readings.
    private var displayedAngle as Lang.Float = 0.0f;
    // User-facing status text shown at the bottom of the screen.
    // Kept in Polish, without diacritics (for font compatibility),
    // on purpose, since this is what the end user sees.
    private var status as Lang.String = "szukam gps...";
    private var distance as Lang.Float = 0.0f;
    private var zabkaBearing as Lang.Float = 0.0f;

    private var myLat as Lang.Double or Null = null;
    private var myLon as Lang.Double or Null = null;
    private var zabkaLat as Lang.Double or Null = null;
    private var zabkaLon as Lang.Double or Null = null;

    // Reliability / retry bookkeeping.
    private var apiInFlight as Lang.Boolean = false;
    // Fires if a request takes longer than REQUEST_TIMEOUT_MS to get
    // a response, so the widget can recover instead of waiting
    // forever.
    private var watchdogTimer as Timer.Timer or Null = null;
    private var retryCount as Lang.Number = 0;
    private var nextRetryAllowedMs as Lang.Number = 0;
    // Which entry of OVERPASS_ENDPOINTS we're currently using; moves
    // to the next one whenever a request fails outright.
    private var endpointIndex as Lang.Number = 0;

    function initialize() {
        View.initialize();
    }

    // Loads the logo bitmap once, when the layout is created.
    function onLayout(dc as Graphics.Dc) as Void {
        logo = WatchUi.loadResource(Rez.Drawables.LogoIcon);
    }

    // Called when the view becomes visible: start listening for
    // compass (sensor) events and GPS position updates.
    function onShow() as Void {
        Sensor.enableSensorEvents(method(:onSensorData));
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
    }

    // Called every time a new GPS fix is available.
    function onPosition(info as Position.Info) as Void {
        var pos = info.position;
        if (pos == null) {
            return;
        }

        var currentPos = pos as Position.Location;
        var loc = currentPos.toDegrees();

        // Safely cast the coordinates to Double for use in the
        // Haversine distance/bearing calculation below.
        myLat = loc[0].toDouble();
        myLon = loc[1].toDouble();

        if (zabkaLat == null) {
            // We don't have a store location yet: request one, but
            // respect the retry backoff so we don't hammer the API
            // on every single GPS fix while offline or between
            // legitimate "nothing nearby" checks.
            if (!apiInFlight && System.getTimer() >= nextRetryAllowedMs) {
                requestZabkaUpdate();
            }
        } else {
            // We already know where the store is: just refresh the
            // distance/bearing as the user moves.
            calculateRouting();
            status = distance.format("%.0f") + " m";
        }

        WatchUi.requestUpdate();
    }

    // Kicks off (or retries) the search for the nearest store.
    function requestZabkaUpdate() as Void {
        if (myLat == null || myLon == null) {
            status = "brak GPS";
            return;
        }
        apiInFlight = true;
        status = "szukam zabki...";
        fetchZabka();

        // Start (or restart) the watchdog: if onReceive hasn't fired
        // within REQUEST_TIMEOUT_MS, onRequestTimeout treats it as a
        // failure so we're never stuck waiting indefinitely.
        watchdogTimer = new Timer.Timer();
        watchdogTimer.start(method(:onRequestTimeout), REQUEST_TIMEOUT_MS, false);
    }

    // Stops and clears the watchdog timer, if one is running.
    function stopWatchdog() as Void {
        if (watchdogTimer != null) {
            (watchdogTimer as Timer.Timer).stop();
            watchdogTimer = null;
        }
    }

    // Called if a request is still in flight REQUEST_TIMEOUT_MS after
    // it started - i.e. makeWebRequest's own callback never fired in
    // a reasonable time (an overloaded/unresponsive mirror, for
    // example). Treated exactly like a failed request: rotate to the
    // next mirror and schedule a backed-off retry, so the widget
    // recovers on its own instead of showing "szukam zabki..."
    // forever.
    function onRequestTimeout() as Void {
        if (!apiInFlight) {
            // The real response actually arrived right around the
            // same time; nothing to do.
            return;
        }

        apiInFlight = false;
        watchdogTimer = null;
        status = "blad: timeout";
        retryCount += 1;
        endpointIndex = (endpointIndex + 1) % OVERPASS_ENDPOINTS.size();
        var delay = RETRY_BASE_DELAY_MS * retryCount;
        if (delay > RETRY_MAX_DELAY_MS) {
            delay = RETRY_MAX_DELAY_MS;
        }
        nextRetryAllowedMs = System.getTimer() + delay;
        WatchUi.requestUpdate();
    }

    // Queries the public Overpass API (OpenStreetMap) for nodes,
    // ways, and relations ("nwr") whose name contains "abka"
    // (matches "Zabka"/"Żabka") within SEARCH_RADIUS_M meters of the
    // current position. Using "nwr" instead of just "node" matters
    // because many real-world shops are mapped as a building outline
    // (a "way") rather than a single point.
    function fetchZabka() as Void {
        // Force a fixed-point decimal format (never scientific
        // notation) for the coordinates, since Overpass QL's parser
        // does not understand scientific notation and Monkey C's
        // default Double-to-String conversion can sometimes produce
        // it for certain values.
        var latStr = (myLat as Lang.Double).format("%.6f");
        var lonStr = (myLon as Lang.Double).format("%.6f");

        var query = "[out:json][timeout:5];nwr(around:" + SEARCH_RADIUS_M + "," + latStr + "," + lonStr + ")[\"name\"~\"abka\",i];out center;";
        // Debug aid: prints the exact query being sent, so it can be
        // copy-pasted into a browser against whichever endpoint is
        // logged below, to inspect the raw response while
        // troubleshooting.
        System.println("Overpass query: " + query);
        var url = OVERPASS_ENDPOINTS[endpointIndex];
        System.println("Overpass endpoint: " + url);

        var params = {
            "data" => query
        };

        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Content-Type" => Communications.REQUEST_CONTENT_TYPE_URL_ENCODED
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };

        Communications.makeWebRequest(url, params, options, method(:onReceive));
    }

    // Callback for the Overpass API request. Picks the *nearest*
    // matching element (not just the first one returned - Overpass
    // does not guarantee any particular order) and schedules a
    // backed-off retry if the request itself failed.
    function onReceive(responseCode as Lang.Number, data as Lang.Dictionary or Null) as Void {
        // A real response arrived, so the watchdog is no longer
        // needed for this request.
        stopWatchdog();
        apiInFlight = false;
        System.println("Overpass response code: " + responseCode + ", data null? " + (data == null));

        if (responseCode == 200 && data != null) {
            var elements = data["elements"] as Lang.Array;
            if (elements != null && elements.size() > 0) {
                var nearest = pickNearestElement(elements);
                zabkaLat = nearest[0] as Lang.Double;
                zabkaLon = nearest[1] as Lang.Double;
                calculateRouting();
                status = distance.format("%.0f") + " m";
                retryCount = 0;
                nextRetryAllowedMs = 0;
            } else {
                // Valid response, but nothing within the search
                // radius - not a failure, just keep checking as the
                // user moves, without spamming the API every second.
                status = "brak zabki w poblizu";
                retryCount = 0;
                nextRetryAllowedMs = System.getTimer() + NO_RESULT_RETRY_DELAY_MS;
            }
        } else {
            // Network or server error - rotate to the next mirror
            // and back off with a growing (capped) delay before
            // trying again automatically.
            status = "blad: " + responseCode;
            retryCount += 1;
            endpointIndex = (endpointIndex + 1) % OVERPASS_ENDPOINTS.size();
            var delay = RETRY_BASE_DELAY_MS * retryCount;
            if (delay > RETRY_MAX_DELAY_MS) {
                delay = RETRY_MAX_DELAY_MS;
            }
            nextRetryAllowedMs = System.getTimer() + delay;
        }

        WatchUi.requestUpdate();
    }

    // Given a list of Overpass "elements", returns the [lat, lon] of
    // the one closest to our current position.
    function pickNearestElement(elements as Lang.Array) as Lang.Array {
        var bestLat = null;
        var bestLon = null;
        var bestDist = null;

        for (var i = 0; i < elements.size(); i++) {
            var candidate = elements[i] as Lang.Dictionary;
            var latLon = extractLatLon(candidate);
            var candLat = latLon[0] as Lang.Double;
            var candLon = latLon[1] as Lang.Double;
            var d = haversineDistance(myLat as Lang.Double, myLon as Lang.Double, candLat, candLon);

            if (bestDist == null || d < (bestDist as Lang.Double)) {
                bestDist = d;
                bestLat = candLat;
                bestLon = candLon;
            }
        }

        return [bestLat, bestLon];
    }

    // Extracts [lat, lon] from a single Overpass element - nodes have
    // lat/lon directly, while ways/relations expose them via
    // "center" instead.
    function extractLatLon(node as Lang.Dictionary) as Lang.Array {
        if (node.hasKey("center")) {
            var center = node["center"] as Lang.Dictionary;
            return [center["lat"].toDouble(), center["lon"].toDouble()];
        }
        return [node["lat"].toDouble(), node["lon"].toDouble()];
    }

    // Great-circle distance between two lat/lon points, in meters
    // (Haversine formula).
    function haversineDistance(lat1 as Lang.Double, lon1 as Lang.Double, lat2 as Lang.Double, lon2 as Lang.Double) as Lang.Double {
        var rLat1 = lat1 * Math.PI / 180.0;
        var rLat2 = lat2 * Math.PI / 180.0;
        var dLat = (lat2 - lat1) * Math.PI / 180.0;
        var dLon = (lon2 - lon1) * Math.PI / 180.0;

        var a = Math.sin(dLat / 2.0) * Math.sin(dLat / 2.0) + Math.cos(rLat1) * Math.cos(rLat2) * Math.sin(dLon / 2.0) * Math.sin(dLon / 2.0);
        var c = 2.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1.0 - a));
        return EARTH_RADIUS_M * c;
    }

    // Computes the distance (via haversineDistance) and the initial
    // compass bearing from the user's position to the store.
    function calculateRouting() as Void {
        if (myLat != null && zabkaLat != null) {
            var lat1 = myLat as Lang.Double;
            var lon1 = myLon as Lang.Double;
            var lat2 = zabkaLat as Lang.Double;
            var lon2 = zabkaLon as Lang.Double;

            distance = haversineDistance(lat1, lon1, lat2, lon2).toFloat();

            var rLat1 = lat1 * Math.PI / 180.0;
            var rLat2 = lat2 * Math.PI / 180.0;
            var dLon = (lon2 - lon1) * Math.PI / 180.0;

            // Initial compass bearing from the user to the store.
            var y = Math.sin(dLon) * Math.cos(rLat2);
            var x = Math.cos(rLat1) * Math.sin(rLat2) - Math.sin(rLat1) * Math.cos(rLat2) * Math.cos(dLon);
            zabkaBearing = Math.atan2(y, x).toFloat();
        }
    }

    // Called whenever a new compass heading is available.
    function onSensorData(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.heading != null) {
            heading = sensorInfo.heading as Lang.Float;
            WatchUi.requestUpdate();
        }
    }

    // Normalizes an angle (radians) to the (-PI, PI] range, so that
    // easing towards it always takes the shortest path around the
    // circle instead of spinning the long way.
    function normalizeAngle(angle as Lang.Float) as Lang.Float {
        var result = angle;
        while (result > Math.PI) {
            result -= 2.0 * Math.PI;
        }
        while (result <= -Math.PI) {
            result += 2.0 * Math.PI;
        }
        return result;
    }

    // Draws the logo, the (smoothed) arrow pointing towards the
    // store, and the current status text.
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

    // Returns the color used for both the arrow and the distance
    // readout, so the two stay visually in sync: gray while
    // searching, orange once found, bright green once close.
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
            targetAngle = normalizeAngle(zabkaBearing - heading);
        }

        // Ease the displayed angle towards the target via the
        // shortest angular path - this removes most of the jitter
        // caused by noisy compass readings, instead of snapping the
        // arrow instantly to every new heading sample.
        var diff = normalizeAngle(targetAngle - displayedAngle);
        displayedAngle = normalizeAngle(displayedAngle + diff * ANGLE_SMOOTHING);

        var cosA = Math.cos(displayedAngle);
        var sinA = Math.sin(displayedAngle);

        // Base arrow shape (pointing "up"), rotated below.
        var arrowPoints = [[0, -40], [20, 30], [0, 15], [-20, 30]];
        // Slightly larger copy of the same shape, drawn first in a
        // dark color, so it reads as a thin outline/border around
        // the colored arrow on top - keeps it visible on any
        // background.
        var outlineScale = 1.25;

        var arrowScreen = new [4];
        var outlineScreen = new [4];

        for (var i = 0; i < 4; i++) {
            var px = arrowPoints[i][0];
            var py = arrowPoints[i][1];

            // Standard 2D rotation matrix applied around the center
            // of the screen.
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
    // the user is within CLOSE_DISTANCE_M of the store, as a subtle
    // "you're basically there" cue.
    function drawCloseIndicator(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float, angle as Lang.Float) as Void {
        // Same rotation formula as the arrow tip point [0, -40].
        var tipX = cx + (40 * Math.sin(angle));
        var tipY = cy - (40 * Math.cos(angle));

        // Pulse the radius over time using a simple sine wave driven
        // by the system clock - no extra timer needed, since
        // onUpdate already runs frequently from compass events.
        var phase = System.getTimer() / 250.0;
        var pulse = 3 + 2 * Math.sin(phase);

        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(tipX, tipY, pulse);
    }

    // Draws the status text: the distance in large colored digits
    // once known, or a smaller plain message while searching or on
    // error.
    function drawStatus(dc as Graphics.Dc, cx as Lang.Float, cy as Lang.Float) as Void {
        var font = Graphics.FONT_MEDIUM;
        var color = Graphics.COLOR_WHITE;

        if (zabkaLat != null) {
            font = Graphics.FONT_NUMBER_MILD;
            color = currentAccentColor();
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 80, font, status, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Called when the view is hidden: stop all sensor/GPS listeners
    // to save battery.
    function onHide() as Void {
        stopWatchdog();
        Sensor.enableSensorEvents(null);
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }
}
