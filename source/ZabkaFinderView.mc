import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Sensor;
import Toybox.Math;
import Toybox.Position;
import Toybox.Communications;
import Toybox.Lang;

// Main (and only) view of the widget.
// Shows an arrow pointing towards the nearest "Zabka" store (a Polish
// convenience store chain) together with the distance to it.
class ZabkaFinderView extends WatchUi.View {

    private var logo;
    private var heading as Lang.Float = 0.0f;
    // User-facing status text shown at the bottom of the screen.
    // Kept in Polish on purpose, since this is what the end user sees.
    private var status as Lang.String = "szukam gps...";
    private var distance as Lang.Float = 0.0f;
    private var zabkaBearing as Lang.Float = 0.0f;

    private var myLat as Lang.Double or Null = null;
    private var myLon as Lang.Double or Null = null;
    private var zabkaLat as Lang.Double or Null = null;
    private var zabkaLon as Lang.Double or Null = null;
    private var lastLocation as Position.Location or Null = null;
    // Prevents sending more than one Overpass API request for the
    // same GPS fix / session.
    private var apiRequested as Lang.Boolean = false;

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
        if (pos != null) {
            var currentPos = pos as Position.Location;
            var loc = currentPos.toDegrees();

            // Safely cast the coordinates to Double for use in the
            // Haversine distance/bearing calculation below.
            myLat = loc[0].toDouble();
            myLon = loc[1].toDouble();

            if (!apiRequested) {
                // First GPS fix in this session: kick off the search
                // for the nearest store via the Overpass API.
                apiRequested = true;
                lastLocation = currentPos;
                status = "szukam zabki...";
                fetchZabka();
            } else if (zabkaLat != null) {
                // We already know where the store is: just refresh
                // the distance/bearing as the user moves.
                calculateRouting();
                status = distance.format("%.0f") + " m";
            }
            WatchUi.requestUpdate();
        }
    }

    // Queries the public Overpass API (OpenStreetMap) for the nearest
    // node whose name contains "abka" (matches "Zabka"/"Żabka") within
    // a 500 meter radius of the current position.
    function fetchZabka() as Void {
        if (myLat == null || myLon == null) {
            status = "brak GPS";
            WatchUi.requestUpdate();
            return;
        }

        var query = "[out:json][timeout:5];node(around:500," + myLat + "," + myLon + ")[\"name\"~\"abka\",i];out center;";
        var url = "https://overpass-api.de/api/interpreter";

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

    // Callback for the Overpass API request. Parses the first
    // matching element and stores its coordinates.
    function onReceive(responseCode as Lang.Number, data as Lang.Dictionary or Null) as Void {
        if (responseCode == 200 && data != null) {
            var elements = data["elements"] as Lang.Array;
            if (elements != null && elements.size() > 0) {
                var zabka = elements[0] as Lang.Dictionary;
                if (zabka.hasKey("center")) {
                    // Result is a way/relation: use its "center" field.
                    var center = zabka["center"] as Lang.Dictionary;
                    zabkaLat = center["lat"].toDouble();
                    zabkaLon = center["lon"].toDouble();
                } else {
                    // Result is a plain node: lat/lon are top-level.
                    zabkaLat = zabka["lat"].toDouble();
                    zabkaLon = zabka["lon"].toDouble();
                }
                calculateRouting();
                status = distance.format("%.0f") + " m";
            } else {
                // No store found within the search radius.
                status = "brak zabki";
            }
        } else {
            // Network or server error - show the HTTP response code.
            status = "blad: " + responseCode;
            // Note: we intentionally do NOT reset apiRequested here,
            // so we don't spam the API with retries on every GPS fix.
            // apiRequested = false;
        }
        WatchUi.requestUpdate();
    }

    // Computes the great-circle distance (Haversine formula) and the
    // initial bearing from the user's position to the store.
    function calculateRouting() as Void {
        if (myLat != null && zabkaLat != null) {
            var rLat1 = myLat * Math.PI / 180.0;
            var rLat2 = zabkaLat * Math.PI / 180.0;
            var dLat = (zabkaLat - myLat) * Math.PI / 180.0;
            var dLon = (zabkaLon - myLon) * Math.PI / 180.0;

            // Haversine formula for the great-circle distance.
            var a = Math.sin(dLat/2.0) * Math.sin(dLat/2.0) + Math.cos(rLat1) * Math.cos(rLat2) * Math.sin(dLon/2.0) * Math.sin(dLon/2.0);
            var c = 2.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1.0-a));
            distance = (6371000.0 * c).toFloat(); // Earth radius in meters.

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

    // Draws the logo, a rotating arrow pointing towards the store,
    // and the current status text.
    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var cy = dc.getHeight() / 2.0;

        if (logo != null) {
            dc.drawBitmap(cx - (logo.getWidth() / 2.0), 20, logo);
        }

        // Arrow rotation = bearing to the store minus our own heading,
        // so the arrow always points towards the store on screen.
        var finalAngle = 0.0f;
        if (zabkaLat != null) {
            finalAngle = zabkaBearing - heading;
        }

        // Base arrow shape (pointing "up"), rotated below.
        var arrowPoints = [[0, -40], [20, 30], [0, 15], [-20, 30]];
        var rotatedPoints = new [4];
        var cos = Math.cos(finalAngle);
        var sin = Math.sin(finalAngle);

        for (var i = 0; i < 4; i++) {
            var px = arrowPoints[i][0];
            var py = arrowPoints[i][1];
            // Standard 2D rotation matrix applied around the center
            // of the screen.
            var rx = (px * cos) - (py * sin);
            var ry = (px * sin) + (py * cos);
            rotatedPoints[i] = [cx + rx, cy + ry];
        }

        // Green arrow once we know where the store is, gray while
        // still searching.
        dc.setColor(zabkaLat != null ? Graphics.COLOR_GREEN : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(rotatedPoints);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 80, Graphics.FONT_MEDIUM, status, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Called when the view is hidden: stop all sensor/GPS listeners
    // to save battery.
    function onHide() as Void {
        Sensor.enableSensorEvents(null);
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }
}
