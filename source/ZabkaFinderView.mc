import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Sensor;
import Toybox.Math;
import Toybox.Position;
import Toybox.Communications;
import Toybox.Lang;

class ZabkaFinderView extends WatchUi.View {

    private var logo;
    private var heading as Lang.Float = 0.0f;
    private var status as Lang.String = "szukam gps...";
    private var distance as Lang.Float = 0.0f;
    private var zabkaBearing as Lang.Float = 0.0f;

    private var myLat as Lang.Double or Null = null;
    private var myLon as Lang.Double or Null = null;
    private var zabkaLat as Lang.Double or Null = null;
    private var zabkaLon as Lang.Double or Null = null;
    private var lastLocation as Position.Location or Null = null;
    private var apiRequested as Lang.Boolean = false;

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Graphics.Dc) as Void {
        logo = WatchUi.loadResource(Rez.Drawables.LogoIcon);
    }

    function onShow() as Void {
        Sensor.enableSensorEvents(method(:onSensorData));
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
    }

    function onPosition(info as Position.Info) as Void {
        var pos = info.position;
        if (pos != null) {
            var currentPos = pos as Position.Location;
            var loc = currentPos.toDegrees();

            // bezpieczne rzutowanie na double
            myLat = loc[0].toDouble();
            myLon = loc[1].toDouble();

            if (!apiRequested) {
                apiRequested = true;
                lastLocation = currentPos;
                status = "szukam zabki...";
                fetchZabka();
            } else if (zabkaLat != null) {
                calculateRouting();
                status = distance.format("%.0f") + " m";
            }
            WatchUi.requestUpdate();
        }
    }

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

    function onReceive(responseCode as Lang.Number, data as Lang.Dictionary or Null) as Void {
        if (responseCode == 200 && data != null) {
            var elements = data["elements"] as Lang.Array;
            if (elements != null && elements.size() > 0) {
                var zabka = elements[0] as Lang.Dictionary;
                if (zabka.hasKey("center")) {
                    var center = zabka["center"] as Lang.Dictionary;
                    zabkaLat = center["lat"].toDouble();
                    zabkaLon = center["lon"].toDouble();
                } else {
                    zabkaLat = zabka["lat"].toDouble();
                    zabkaLon = zabka["lon"].toDouble();
                }
                calculateRouting();
                status = distance.format("%.0f") + " m";
            } else {
                status = "brak zabki";
            }
        } else {
            status = "blad: " + responseCode;
            // apiRequested = false;
        }
        WatchUi.requestUpdate();
    }

    function calculateRouting() as Void {
        if (myLat != null && zabkaLat != null) {
            var rLat1 = myLat * Math.PI / 180.0;
            var rLat2 = zabkaLat * Math.PI / 180.0;
            var dLat = (zabkaLat - myLat) * Math.PI / 180.0;
            var dLon = (zabkaLon - myLon) * Math.PI / 180.0;

            var a = Math.sin(dLat/2.0) * Math.sin(dLat/2.0) + Math.cos(rLat1) * Math.cos(rLat2) * Math.sin(dLon/2.0) * Math.sin(dLon/2.0);
            var c = 2.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1.0-a));
            distance = (6371000.0 * c).toFloat();

            var y = Math.sin(dLon) * Math.cos(rLat2);
            var x = Math.cos(rLat1) * Math.sin(rLat2) - Math.sin(rLat1) * Math.cos(rLat2) * Math.cos(dLon);
            zabkaBearing = Math.atan2(y, x).toFloat();
        }
    }

    function onSensorData(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.heading != null) {
            heading = sensorInfo.heading as Lang.Float;
            WatchUi.requestUpdate();
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var cy = dc.getHeight() / 2.0;

        if (logo != null) {
            dc.drawBitmap(cx - (logo.getWidth() / 2.0), 20, logo);
        }

        var finalAngle = 0.0f;
        if (zabkaLat != null) {
            finalAngle = zabkaBearing - heading;
        }

        var arrowPoints = [[0, -40], [20, 30], [0, 15], [-20, 30]];
        var rotatedPoints = new [4];
        var cos = Math.cos(finalAngle);
        var sin = Math.sin(finalAngle);

        for (var i = 0; i < 4; i++) {
            var px = arrowPoints[i][0];
            var py = arrowPoints[i][1];
            var rx = (px * cos) - (py * sin);
            var ry = (px * sin) + (py * cos);
            rotatedPoints[i] = [cx + rx, cy + ry];
        }

        dc.setColor(zabkaLat != null ? Graphics.COLOR_GREEN : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(rotatedPoints);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 80, Graphics.FONT_MEDIUM, status, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function onHide() as Void {
        Sensor.enableSensorEvents(null);
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }
}