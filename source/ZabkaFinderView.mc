import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Sensor;
import Toybox.Math;
import Toybox.Position;
import Toybox.Communications;
import Toybox.Lang;

class ZabkaFinderView extends WatchUi.View {

    private var logo;
    private var heading = 0.0;
    private var status = "Szukam GPS...";
    private var distance = 0.0;
    private var zabkaBearing = 0.0;

    private var myLat = null;
    private var myLon = null;
    private var zabkaLat = null;
    private var zabkaLon = null;
    private var lastlocation = null;

    private var apiRequested = false;

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Dc) as Void {
        logo = WatchUi.loadResource(Rez.Drawables.LogoIcon);
    }

    function onShow() as Void {
        Sensor.enableSensorEvents(method(:onSensorData));
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
    }

    function onPosition(info as Position.Info) as Void {
        if (info.position != null) {
            var loc = info.position.toDegrees();
            myLat = loc[0];
            myLon = loc[1];

            if (!apiRequested) {
                apiRequested = true;
                status = "Szukam Zabki...";
                fetchZabka();
            } else if (zabkaLat != null) {
                calculateRouting();
                status = distance.format("%.0f") + " m";
            }
            WatchUi.requestUpdate();
        }
    }

function fetchZabka() as Void {
        var url = "https://overpass-api.de/api/interpreter";

        var query = "[out:json];(node(around:2000," + myLat + "," + myLon + ")[\"shop\"=\"convenience\"][\"name\"~\"abka\"];way(around:2000," + myLat + "," + myLon + ")[\"shop\"=\"convenience\"][\"name\"~\"abka\"];relation(around:2000," + myLat + "," + myLon + ")[\"shop\"=\"convenience\"][\"name\"~\"abka\"];);out center 1;";

        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };

        var params = {
            "data" => query
        };

        Communications.makeWebRequest(url, params, options, method(:onReceive));
    }

    function onReceive(responseCode as Lang.Number, data as Lang.Dictionary or Null) as Void {
        if (responseCode == 200 && data != null) {
            var elements = data["elements"];
            if (elements != null && elements.size() > 0) {
                var zabka = elements[0];

                // sprawdzamy czy api zwrocilo obrys (way) z centrem, czy zwykly punkt (node)
                if (zabka.hasKey("center")) {
                    zabkaLat = zabka["center"]["lat"];
                    zabkaLon = zabka["center"]["lon"];
                } else {
                    zabkaLat = zabka["lat"];
                    zabkaLon = zabka["lon"];
                }

                calculateRouting();
                status = distance.format("%.0f") + " m";
            } else {
                status = "brak zabki";
            }
        } else {
            status = "blad api: " + responseCode;
            apiRequested = false;
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
            distance = 6371000.0 * c;

            var y = Math.sin(dLon) * Math.cos(rLat2);
            var x = Math.cos(rLat1) * Math.sin(rLat2) - Math.sin(rLat1) * Math.cos(rLat2) * Math.cos(dLon);
            zabkaBearing = Math.atan2(y, x);
        }
    }

    function onSensorData(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.heading != null) {
            heading = sensorInfo.heading;
            WatchUi.requestUpdate();
        }
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2.0;
        var cy = dc.getHeight() / 2.0;

        if (logo != null) {
            dc.drawBitmap(cx - (logo.getWidth() / 2.0), 20, logo);
        }

        var finalAngle = heading;
        if (zabkaLat != null) {
            finalAngle = zabkaBearing - heading;
        }

        var arrowPoints = [
            [0, -40],
            [20, 30],
            [0, 15],
            [-20, 30]
        ];

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

        if (zabkaLat != null) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        } else {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        }
        dc.fillPolygon(rotatedPoints);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 80, Graphics.FONT_MEDIUM, status, Graphics.TEXT_JUSTIFY_CENTER);
    }

    function onHide() as Void {
        Sensor.enableSensorEvents(null);
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }
}