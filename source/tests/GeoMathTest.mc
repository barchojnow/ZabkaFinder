import Toybox.Lang;
import Toybox.Math;
import Toybox.Test;

// Unit tests for GeoMath. These only exist in test builds: the
// (:test) annotation keeps them out of release binaries, which
// matters on watches where every KB of the app counts.
//
// Run: VS Code -> "Monkey C: Run Tests" (or monkeydo <prg> <device> -t)
//
// Reference values were computed independently (Python/Haversine)
// rather than by running this code, so a bug in GeoMath can't
// silently define its own "expected" result.
module GeoMathTest {

    // Warsaw city centre - all fixtures are offsets from here.
    const LAT = 52.2297d;
    const LON = 21.0122d;

    function closeTo(actual as Lang.Double, expected as Lang.Double,
                     tolerance as Lang.Double, logger as Test.Logger,
                     label as Lang.String) as Lang.Boolean {
        var diff = actual - expected;
        if (diff < 0) {
            diff = -diff;
        }
        if (diff > tolerance) {
            logger.error(label + ": expected " + expected + " +/- " + tolerance
                + ", got " + actual);
            return false;
        }
        return true;
    }

    // --- haversineDistance ---------------------------------------------

    (:test)
    function distanceToSelfIsZero(logger as Test.Logger) as Lang.Boolean {
        var d = GeoMath.haversineDistance(LAT, LON, LAT, LON);
        return closeTo(d, 0.0d, 0.001d, logger, "distance to self");
    }

    // 0.001 degrees of latitude is ~111.19 m anywhere on Earth.
    (:test)
    function distanceOneMilliDegreeNorth(logger as Test.Logger) as Lang.Boolean {
        var d = GeoMath.haversineDistance(LAT, LON, LAT + 0.001d, LON);
        return closeTo(d, 111.19d, 0.5d, logger, "111 m north");
    }

    // Longitude degrees shrink with latitude: at 52.23 N one milli
    // degree of longitude is ~68.11 m, not 111 m. Catches a lat/lon
    // mix-up, which would otherwise stay invisible.
    (:test)
    function distanceOneMilliDegreeEast(logger as Test.Logger) as Lang.Boolean {
        var d = GeoMath.haversineDistance(LAT, LON, LAT, LON + 0.001d);
        return closeTo(d, 68.11d, 0.5d, logger, "68 m east");
    }

    (:test)
    function distanceIsSymmetric(logger as Test.Logger) as Lang.Boolean {
        var a = GeoMath.haversineDistance(LAT, LON, 50.0647d, 19.9450d);
        var b = GeoMath.haversineDistance(50.0647d, 19.9450d, LAT, LON);
        return closeTo(a, b, 0.001d, logger, "symmetry");
    }

    // Warsaw -> Krakow, ~252 km: verifies the formula still holds at
    // a scale where flat-earth approximations would drift.
    (:test)
    function distanceLongRange(logger as Test.Logger) as Lang.Boolean {
        var d = GeoMath.haversineDistance(LAT, LON, 50.0647d, 19.9450d);
        return closeTo(d, 252000.0d, 1000.0d, logger, "Warsaw-Krakow");
    }

    // --- initialBearing -------------------------------------------------

    (:test)
    function bearingCardinalDirections(logger as Test.Logger) as Lang.Boolean {
        var north = GeoMath.initialBearing(LAT, LON, LAT + 0.01d, LON);
        var east  = GeoMath.initialBearing(LAT, LON, LAT, LON + 0.01d);
        var south = GeoMath.initialBearing(LAT, LON, LAT - 0.01d, LON);
        var west  = GeoMath.initialBearing(LAT, LON, LAT, LON - 0.01d);

        // Math.PI is a Float in Monkey C, so anything derived from it
        // needs an explicit toDouble() to match closeTo's signature.
        var halfPi = (Math.PI / 2.0).toDouble();
        var ok = closeTo(north.toDouble(), 0.0d, 0.01d, logger, "north");
        ok = closeTo(east.toDouble(), halfPi, 0.01d, logger, "east") && ok;
        ok = closeTo(south.toDouble(), Math.PI.toDouble(), 0.01d, logger, "south") && ok;
        ok = closeTo(west.toDouble(), -halfPi, 0.01d, logger, "west") && ok;
        return ok;
    }

    // --- normalizeAngle -------------------------------------------------

    (:test)
    function normalizeWrapsIntoRange(logger as Test.Logger) as Lang.Boolean {
        var halfPi = (Math.PI / 2.0).toDouble();
        var ok = closeTo(GeoMath.normalizeAngle((3.0 * Math.PI / 2.0).toFloat()).toDouble(),
            -halfPi, 0.0001d, logger, "3pi/2 -> -pi/2");
        ok = closeTo(GeoMath.normalizeAngle((-3.0 * Math.PI / 2.0).toFloat()).toDouble(),
            halfPi, 0.0001d, logger, "-3pi/2 -> pi/2") && ok;
        ok = closeTo(GeoMath.normalizeAngle(0.5f).toDouble(),
            0.5d, 0.0001d, logger, "in-range value untouched") && ok;
        return ok;
    }

    // Several full turns must still land in (-PI, PI] - the arrow
    // easing relies on this to always take the shortest path.
    (:test)
    function normalizeHandlesManyTurns(logger as Test.Logger) as Lang.Boolean {
        var angle = GeoMath.normalizeAngle((7.0 * Math.PI).toFloat());
        if (angle > Math.PI || angle <= -Math.PI) {
            logger.error("out of range: " + angle);
            return false;
        }
        return true;
    }
}
