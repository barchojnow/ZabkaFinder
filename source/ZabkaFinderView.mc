import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Sensor;
import Toybox.Math;

class ZabkaFinderView extends WatchUi.View {

    private var logo;
    private var heading = 0.0;

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Dc) as Void {
        logo = WatchUi.loadResource(Rez.Drawables.LogoIcon);
    }

    function onShow() as Void {
        Sensor.enableSensorEvents(method(:onSensorData));
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

        var arrowPoints = [
            [0, -40],
            [20, 30],
            [0, 15],
            [-20, 30]
        ];

        var rotatedPoints = new [4];
        var cos = Math.cos(heading);
        var sin = Math.sin(heading);

        for (var i = 0; i < 4; i++) {
            var px = arrowPoints[i][0];
            var py = arrowPoints[i][1];

            var rx = (px * cos) - (py * sin);
            var ry = (px * sin) + (py * cos);

            rotatedPoints[i] = [cx + rx, cy + ry];
        }

        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(rotatedPoints);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy + 80, Graphics.FONT_MEDIUM, "Szukam...", Graphics.TEXT_JUSTIFY_CENTER);
    }

    function onHide() as Void {
        Sensor.enableSensorEvents(null);
    }
}