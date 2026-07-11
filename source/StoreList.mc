import Toybox.Lang;

// The collection of known Zabka stores: filtering fresh search
// results to the true circular radius, merging them with previously
// known entries, distance-sorting and menu queries. Pure data logic -
// no UI, no networking.
//
// Entries are Dictionaries {:lat, :lon, :addr} plus a :dist key
// refreshed by sortByDistance(). Menu item ids are indices into this
// list, so sorting always happens on the internal array itself.
class StoreList {

    // Two entries closer than this to each other are treated as the
    // same store (GPS/OSM coordinate noise between refreshes).
    const DUPLICATE_EPSILON_M = 25.0;

    private var stores as Lang.Array = [];

    function size() as Lang.Number {
        return stores.size();
    }

    function get(index as Lang.Number) as Lang.Dictionary or Null {
        if (index < 0 || index >= stores.size()) {
            return null;
        }
        return stores[index] as Lang.Dictionary;
    }

    // The current nearest store - only meaningful right after
    // sortByDistance().
    function nearest() as Lang.Dictionary or Null {
        return get(0);
    }

    // Takes freshly parsed store entries, filters them to radiusM
    // around (lat, lon), merges them with previously known stores and
    // adopts the result. Returns how many FRESH entries were in range
    // (the caller uses that to drive the retry backoff: a search that
    // found nothing schedules a quicker re-check).
    function update(coords as Lang.Array, lat as Lang.Double, lon as Lang.Double,
                    radiusM as Lang.Number) as Lang.Number {
        var fresh = buildSorted(coords, lat, lon, radiusM);
        var freshCount = fresh.size();

        // Merge instead of replace: previously known stores that are
        // still within range survive a refresh that didn't re-find
        // them (Nominatim's relevance ranking can drop results
        // between calls), so the list only ever *gains* knowledge.
        // Fresh data wins on duplicates.
        for (var i = 0; i < stores.size(); i++) {
            var old = stores[i] as Lang.Dictionary;
            var oLat = old[:lat] as Lang.Double;
            var oLon = old[:lon] as Lang.Double;

            if (GeoMath.haversineDistance(lat, lon, oLat, oLon) > radiusM) {
                continue;
            }
            var duplicate = false;
            for (var j = 0; j < freshCount; j++) {
                var f = fresh[j] as Lang.Dictionary;
                if (GeoMath.haversineDistance(oLat, oLon,
                        f[:lat] as Lang.Double, f[:lon] as Lang.Double) < DUPLICATE_EPSILON_M) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                fresh.add(old);
            }
        }

        stores = fresh;
        return freshCount;
    }

    // Re-sorts the whole list ascending by distance from (lat, lon),
    // storing the fresh distance in each entry's :dist. Must operate
    // on the internal array because menu ids are indices into it.
    // Insertion sort - at most a few dozen entries.
    function sortByDistance(lat as Lang.Double, lon as Lang.Double) as Void {
        var sorted = [] as Lang.Array;
        for (var i = 0; i < stores.size(); i++) {
            var s = stores[i] as Lang.Dictionary;
            var d = GeoMath.haversineDistance(lat, lon, s[:lat] as Lang.Double, s[:lon] as Lang.Double);
            s[:dist] = d;

            var pos = 0;
            while (pos < sorted.size()
                   && ((sorted[pos] as Lang.Dictionary)[:dist] as Lang.Double) <= d) {
                pos += 1;
            }
            sorted.add(null);
            for (var j = sorted.size() - 1; j > pos; j--) {
                sorted[j] = sorted[j - 1];
            }
            sorted[pos] = s;
        }
        stores = sorted;
    }

    // Returns up to `max` stores as copies {:lat, :lon, :addr, :dist}
    // for the selection menu, freshly re-sorted by distance from the
    // current position (so menu ids keep matching internal indices).
    function getNearest(max as Lang.Number, lat as Lang.Double, lon as Lang.Double) as Lang.Array {
        sortByDistance(lat, lon);
        var result = [] as Lang.Array;
        var count = stores.size() < max ? stores.size() : max;
        for (var i = 0; i < count; i++) {
            var s = stores[i] as Lang.Dictionary;
            result.add({ :lat => s[:lat], :lon => s[:lon], :addr => s[:addr], :dist => s[:dist] });
        }
        return result;
    }

    // Filters raw entries down to radiusM around (lat, lon), sorted
    // ascending by distance (insertion sort).
    private function buildSorted(coords as Lang.Array, lat as Lang.Double,
                                 lon as Lang.Double, radiusM as Lang.Number) as Lang.Array {
        var list = [] as Lang.Array;
        var dists = [] as Lang.Array;

        for (var i = 0; i < coords.size(); i++) {
            var entry = coords[i] as Lang.Dictionary;
            var candLat = entry[:lat] as Lang.Double;
            var candLon = entry[:lon] as Lang.Double;
            var d = GeoMath.haversineDistance(lat, lon, candLat, candLon);
            if (d > radiusM) {
                continue;
            }

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
}
