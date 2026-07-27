import Toybox.Lang;
import Toybox.Test;

// Unit tests for StoreList - the radius filtering, merging and
// distance sorting that decide which store the arrow points to.
// This is where a silent bug is most expensive (users walk the wrong
// way), and it's pure logic, so it's fully testable off-device.
module StoreListTest {

    const LAT = 52.2297d;
    const LON = 21.0122d;
    // 1 milli-degree of latitude is ~111.19 m, so offsets below are
    // easy to reason about: +0.002 = ~222 m, +0.01 = ~1112 m.
    const RADIUS_M = 1000;

    function store(latOffset as Lang.Double, addr as Lang.String) as Lang.Dictionary {
        return { :lat => LAT + latOffset, :lon => LON, :addr => addr };
    }

    // --- radius filtering ------------------------------------------------

    (:test)
    function dropsStoresBeyondRadius(logger as Test.Logger) as Lang.Boolean {
        var list = new StoreList();
        var fresh = [
            store(0.002d, "in range ~222 m"),
            store(0.02d, "out of range ~2224 m")
        ];
        var count = list.update(fresh, LAT, LON, RADIUS_M);

        if (count != 1 || list.size() != 1) {
            logger.error("expected 1 store in range, got fresh=" + count
                + " total=" + list.size());
            return false;
        }
        var kept = list.get(0) as Lang.Dictionary;
        if (!kept[:addr].equals("in range ~222 m")) {
            logger.error("wrong store kept: " + kept[:addr]);
            return false;
        }
        return true;
    }

    // --- sorting ---------------------------------------------------------

    (:test)
    function sortsByDistanceAscending(logger as Test.Logger) as Lang.Boolean {
        var list = new StoreList();
        list.update([
            store(0.004d, "far"),
            store(0.0005d, "near"),
            store(0.002d, "mid")
        ], LAT, LON, RADIUS_M);
        list.sortByDistance(LAT, LON);

        var expected = ["near", "mid", "far"];
        for (var i = 0; i < expected.size(); i++) {
            var s = list.get(i) as Lang.Dictionary;
            if (!s[:addr].equals(expected[i])) {
                logger.error("position " + i + ": expected " + expected[i]
                    + ", got " + s[:addr]);
                return false;
            }
        }
        return true;
    }

    // Sorting must follow the CURRENT position, not the one the
    // search ran from - this is what keeps the menu honest as the
    // user walks (an early bug: order froze at search time).
    (:test)
    function sortFollowsCurrentPosition(logger as Test.Logger) as Lang.Boolean {
        var list = new StoreList();
        list.update([
            store(0.0005d, "north"),
            store(-0.004d, "south")
        ], LAT, LON, RADIUS_M);

        // Walk south, past the southern store.
        var walkedLat = LAT - 0.005d;
        list.sortByDistance(walkedLat, LON);

        var nearest = list.nearest() as Lang.Dictionary;
        if (!nearest[:addr].equals("south")) {
            logger.error("after walking south the nearest should be 'south', got "
                + nearest[:addr]);
            return false;
        }
        return true;
    }

    // --- merging ---------------------------------------------------------

    // Nominatim ranks by relevance, so a refresh can silently omit a
    // store that is still there. Known stores must survive that.
    (:test)
    function keepsKnownStoreMissingFromRefresh(logger as Test.Logger) as Lang.Boolean {
        var list = new StoreList();
        list.update([store(0.0005d, "known")], LAT, LON, RADIUS_M);

        // Refresh returns a different store only.
        list.update([store(0.002d, "fresh")], LAT, LON, RADIUS_M);

        if (list.size() != 2) {
            logger.error("expected both stores after merge, got " + list.size());
            return false;
        }
        return true;
    }

    // The same store can come back with slightly different OSM
    // coordinates; anything within 25 m is the same shop.
    (:test)
    function deduplicatesNearIdenticalStores(logger as Test.Logger) as Lang.Boolean {
        var list = new StoreList();
        list.update([store(0.0005d, "old copy")], LAT, LON, RADIUS_M);

        // ~11 m away: same store, fresh data.
        list.update([store(0.0006d, "fresh copy")], LAT, LON, RADIUS_M);

        if (list.size() != 1) {
            logger.error("expected dedup to 1 store, got " + list.size());
            return false;
        }
        var kept = list.get(0) as Lang.Dictionary;
        if (!kept[:addr].equals("fresh copy")) {
            logger.error("fresh data should win, got " + kept[:addr]);
            return false;
        }
        return true;
    }

    // Walking away must eventually drop stale entries, or the list
    // would grow forever as the user moves across a city.
    (:test)
    function dropsKnownStoreOnceOutOfRange(logger as Test.Logger) as Lang.Boolean {
        var list = new StoreList();
        list.update([store(0.0005d, "left behind")], LAT, LON, RADIUS_M);

        // Walk ~2.2 km north, refresh finds something else.
        var walkedLat = LAT + 0.02d;
        list.update([{ :lat => walkedLat, :lon => LON, :addr => "new area" }],
            walkedLat, LON, RADIUS_M);

        if (list.size() != 1) {
            logger.error("stale store should be dropped, size=" + list.size());
            return false;
        }
        var kept = list.get(0) as Lang.Dictionary;
        if (!kept[:addr].equals("new area")) {
            logger.error("wrong store kept: " + kept[:addr]);
            return false;
        }
        return true;
    }

    // --- menu query ------------------------------------------------------

    (:test)
    function getNearestRespectsLimitAndOrder(logger as Test.Logger) as Lang.Boolean {
        var list = new StoreList();
        list.update([
            store(0.004d, "d"),
            store(0.0005d, "a"),
            store(0.003d, "c"),
            store(0.002d, "b")
        ], LAT, LON, RADIUS_M);

        var top = list.getNearest(2, LAT, LON);
        if (top.size() != 2) {
            logger.error("expected 2 entries, got " + top.size());
            return false;
        }
        var first = top[0] as Lang.Dictionary;
        var second = top[1] as Lang.Dictionary;
        if (!first[:addr].equals("a") || !second[:addr].equals("b")) {
            logger.error("wrong order: " + first[:addr] + ", " + second[:addr]);
            return false;
        }
        // Menu labels need a distance for every entry.
        if (first[:dist] == null || (first[:dist] as Lang.Double) <= 0) {
            logger.error("missing :dist on menu entry");
            return false;
        }
        return true;
    }

    (:test)
    function emptyResultLeavesEmptyList(logger as Test.Logger) as Lang.Boolean {
        var list = new StoreList();
        var count = list.update([], LAT, LON, RADIUS_M);
        if (count != 0 || list.size() != 0 || list.nearest() != null) {
            logger.error("empty update should leave an empty list");
            return false;
        }
        return true;
    }
}
