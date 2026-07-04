import Toybox.Lang;
import Toybox.Math;

// Pure math helpers shared by the view, the API client and the store
// menu. No UI or network dependencies, so everything here is trivially
// unit-testable and reusable.
module GeoMath {

    // Mean Earth radius in meters, used both by the Haversine formula
    // and to size the Nominatim search bounding box.
    const EARTH_RADIUS_M = 6371000.0d;

    function toRadians(deg as Lang.Double) as Lang.Double {
        return deg * Math.PI / 180.0;
    }

    // Great-circle distance between two lat/lon points, in meters
    // (Haversine formula).
    function haversineDistance(lat1 as Lang.Double, lon1 as Lang.Double,
                               lat2 as Lang.Double, lon2 as Lang.Double) as Lang.Double {
        var rLat1 = toRadians(lat1);
        var rLat2 = toRadians(lat2);
        var dLat = toRadians(lat2 - lat1);
        var dLon = toRadians(lon2 - lon1);

        var a = Math.sin(dLat / 2.0) * Math.sin(dLat / 2.0)
              + Math.cos(rLat1) * Math.cos(rLat2) * Math.sin(dLon / 2.0) * Math.sin(dLon / 2.0);
        var c = 2.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1.0 - a));
        return EARTH_RADIUS_M * c;
    }

    // Initial compass bearing (radians) from point 1 towards point 2.
    function initialBearing(lat1 as Lang.Double, lon1 as Lang.Double,
                            lat2 as Lang.Double, lon2 as Lang.Double) as Lang.Float {
        var rLat1 = toRadians(lat1);
        var rLat2 = toRadians(lat2);
        var dLon = toRadians(lon2 - lon1);

        var y = Math.sin(dLon) * Math.cos(rLat2);
        var x = Math.cos(rLat1) * Math.sin(rLat2)
              - Math.sin(rLat1) * Math.cos(rLat2) * Math.cos(dLon);
        return Math.atan2(y, x).toFloat();
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
}
