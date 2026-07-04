import Toybox.Communications;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;

// Everything related to talking to the Nominatim search API lives
// here: building the request, the watchdog timeout, retry backoff
// bookkeeping and parsing the GeoJSON response into plain [lat, lon]
// pairs. The view never touches Communications directly.
//
// Nominatim (OpenStreetMap's search/geocoding service - the same one
// behind the search box on openstreetmap.org) is used instead of the
// Overpass API. Overpass is community/volunteer-run and, as of
// mid-2026, was intermittently unusable. Nominatim's public instance
// is core OSM Foundation infrastructure, built specifically to serve
// many small interactive lookups like this one.
//
// Usage policy compliance:
// - Max 1 request/second: retry backoff never goes below
//   RETRY_BASE_DELAY_MS (5s), and only one request is ever in flight
//   at a time (inFlight), so we're always well under.
// - A descriptive User-Agent identifying the app is sent, as
//   requested for non-bulk users of the shared public instance.
class NominatimClient {

    // Search radius, in meters, around the current position.
    const SEARCH_RADIUS_M = 500;
    // Backoff for retries after a failed (non-200 / network error)
    // request. The delay grows with each consecutive failure, capped
    // at RETRY_MAX_DELAY_MS.
    const RETRY_BASE_DELAY_MS = 5000;
    const RETRY_MAX_DELAY_MS = 30000;
    // How long to wait before re-checking after a *successful*
    // request that legitimately found no store nearby.
    const NO_RESULT_RETRY_DELAY_MS = 10000;
    // Hard ceiling on how long we wait for a single request before
    // giving up on it entirely, even if makeWebRequest's own callback
    // never fires.
    const REQUEST_TIMEOUT_MS = 25000;
    // Synthetic response code passed to the result callback when the
    // watchdog fires before any real response arrived.
    const TIMEOUT_RESPONSE_CODE = -999;

    const NOMINATIM_URL = "https://nominatim.openstreetmap.org/search";

    // Result callback: invoked as callback.invoke(responseCode, coords)
    // where coords is an Array of [lat, lon] Double pairs on success
    // (HTTP 200), or null on any failure/timeout.
    private var resultCallback as (Method(responseCode as Lang.Number, coords as Lang.Array or Null) as Void);

    private var inFlight as Lang.Boolean = false;
    private var watchdogTimer as Timer.Timer or Null = null;
    private var retryCount as Lang.Number = 0;
    private var nextRetryAllowedMs as Lang.Number = 0;

    function initialize(callback as (Method(responseCode as Lang.Number, coords as Lang.Array or Null) as Void)) {
        resultCallback = callback;
    }

    // True when it's OK to fire a new request: nothing in flight and
    // the retry backoff window has elapsed.
    function shouldRequest() as Lang.Boolean {
        return !inFlight && System.getTimer() >= nextRetryAllowedMs;
    }

    // Queries Nominatim for places named "Zabka" within a small
    // bounding box around the given position.
    function search(lat as Lang.Double, lon as Lang.Double) as Void {
        inFlight = true;

        // Build a bounding box of roughly SEARCH_RADIUS_M around the
        // current position. Nominatim's "viewbox" is a rectangle, not
        // a circle, so results must still be filtered down to the
        // true radius by the caller.
        var latRad = GeoMath.toRadians(lat);
        var latDelta = (SEARCH_RADIUS_M / GeoMath.EARTH_RADIUS_M) * (180.0 / Math.PI);
        var lonDelta = (SEARCH_RADIUS_M / (GeoMath.EARTH_RADIUS_M * Math.cos(latRad))) * (180.0 / Math.PI);

        var latMinStr = (lat - latDelta).format("%.6f");
        var latMaxStr = (lat + latDelta).format("%.6f");
        var lonMinStr = (lon - lonDelta).format("%.6f");
        var lonMaxStr = (lon + lonDelta).format("%.6f");

        // Nominatim's viewbox order is left,top,right,bottom, i.e.
        // lonMin,latMax,lonMax,latMin.
        var viewbox = lonMinStr + "," + latMaxStr + "," + lonMaxStr + "," + latMinStr;

        // "Zabka" (no diacritics) rather than "Żabka": Monkey C
        // source files and Garmin's watch fonts have inconsistent
        // support for Polish diacritics, and Nominatim normalizes
        // accents anyway.
        var params = {
            "q" => "Zabka",
            "format" => "geojson",
            "limit" => "20",
            "viewbox" => viewbox,
            "bounded" => "1",
            // Structured address parts (road, house number) in each
            // feature's properties, used for the store menu labels.
            "addressdetails" => "1"
        };

        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => {
                "User-Agent" => "ZabkaFinder-GarminWidget/1.0 (open-source hobby project)"
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };

        System.println("Nominatim viewbox: " + viewbox);

        Communications.makeWebRequest(NOMINATIM_URL, params, options, method(:onReceive));

        // Start (or restart) the watchdog: if onReceive hasn't fired
        // within REQUEST_TIMEOUT_MS, onRequestTimeout treats it as a
        // failure so we're never stuck waiting indefinitely.
        watchdogTimer = new Timer.Timer();
        (watchdogTimer as Timer.Timer).start(method(:onRequestTimeout), REQUEST_TIMEOUT_MS, false);
    }

    // Stops and clears the watchdog timer, if one is running. Also
    // called by the view's onHide() so no timer outlives the view.
    function stopWatchdog() as Void {
        if (watchdogTimer != null) {
            (watchdogTimer as Timer.Timer).stop();
            watchdogTimer = null;
        }
    }

    // Called if a request is still in flight REQUEST_TIMEOUT_MS after
    // it started. Treated exactly like a failed request.
    function onRequestTimeout() as Void {
        if (!inFlight) {
            // The real response arrived right around the same time.
            return;
        }
        inFlight = false;
        watchdogTimer = null;
        registerFailure();
        resultCallback.invoke(TIMEOUT_RESPONSE_CODE, null);
    }

    // makeWebRequest callback: parses the GeoJSON FeatureCollection
    // into an array of [lat, lon] pairs and forwards it to the owner.
    function onReceive(responseCode as Lang.Number, data as Lang.Dictionary or Null) as Void {
        stopWatchdog();
        inFlight = false;
        System.println("Nominatim response code: " + responseCode + ", data null? " + (data == null));

        if (responseCode == 200 && data != null) {
            // GeoJSON FeatureCollection: {"type":"FeatureCollection","features":[...]}.
            // Using format=geojson (an object) rather than plain
            // format=json (a top-level array) matters: Connect IQ's
            // automatic JSON parsing rejects a top-level array with
            // an INVALID_HTTP_BODY error.
            var features = data["features"] as Lang.Array or Null;
            resultCallback.invoke(responseCode, parseFeatures(features));
        } else {
            registerFailure();
            resultCallback.invoke(responseCode, null);
        }
    }

    // Converts the GeoJSON "features" array into an array of
    // dictionaries {:lat, :lon, :addr}. GeoJSON coordinate order is
    // [longitude, latitude] - the opposite of the [lat, lon]
    // convention used everywhere else in this app.
    private function parseFeatures(features as Lang.Array or Null) as Lang.Array {
        var result = [] as Lang.Array;
        if (features == null) {
            return result;
        }
        for (var i = 0; i < features.size(); i++) {
            var feature = features[i] as Lang.Dictionary;
            var geometry = feature["geometry"] as Lang.Dictionary;
            var pair = geometry["coordinates"] as Lang.Array;
            result.add({
                :lat => pair[1].toDouble(),
                :lon => pair[0].toDouble(),
                :addr => extractAddress(feature)
            });
        }
        return result;
    }

    // Builds a short human-readable address ("Kwiatowa 5") from the
    // feature's addressdetails, falling back to the first segment of
    // display_name, then to a plain "Zabka".
    private function extractAddress(feature as Lang.Dictionary) as Lang.String {
        var props = feature["properties"] as Lang.Dictionary or Null;
        if (props == null) {
            return "Zabka";
        }

        var addrDict = props["address"] as Lang.Dictionary or Null;
        if (addrDict != null) {
            var road = addrDict["road"];
            if (road != null) {
                var label = road as Lang.String;
                var houseNumber = addrDict["house_number"];
                if (houseNumber != null) {
                    label = label + " " + houseNumber;
                }
                return foldDiacritics(label);
            }
        }

        // Fallback: "Żabka, Kwiatowa 5, Kraków, ..." -> first
        // non-"Zabka" segment of display_name.
        var displayName = props["display_name"];
        if (displayName != null) {
            var s = displayName as Lang.String;
            var comma = s.find(",");
            if (comma != null) {
                s = s.substring(0, comma) as Lang.String;
            }
            return foldDiacritics(s);
        }
        return "Zabka";
    }

    // Replaces Polish diacritics with plain ASCII, since glyph
    // support for them varies across Garmin's built-in fonts (same
    // reason the whole UI avoids them).
    private function foldDiacritics(text as Lang.String) as Lang.String {
        var map = {
            261 => "a", 263 => "c", 281 => "e", 322 => "l", 324 => "n",
            243 => "o", 347 => "s", 378 => "z", 380 => "z",
            260 => "A", 262 => "C", 280 => "E", 321 => "L", 323 => "N",
            211 => "O", 346 => "S", 377 => "Z", 379 => "Z"
        };
        var chars = text.toCharArray();
        var out = "";
        for (var i = 0; i < chars.size(); i++) {
            var code = (chars[i] as Lang.Char).toNumber();
            var mapped = map[code];
            out += (mapped != null) ? mapped : chars[i].toString();
        }
        return out;
    }

    // --- Backoff bookkeeping ---------------------------------------------
    // The owner reports the *semantic* outcome (success with results,
    // success without results) after filtering by true radius; network
    // failures are registered internally.

    function registerSuccess() as Void {
        retryCount = 0;
        nextRetryAllowedMs = 0;
    }

    function registerNoResult() as Void {
        // Valid response, but nothing within the search radius - not
        // a failure, just re-check later as the user moves, without
        // spamming the API.
        retryCount = 0;
        nextRetryAllowedMs = System.getTimer() + NO_RESULT_RETRY_DELAY_MS;
    }

    private function registerFailure() as Void {
        retryCount += 1;
        var delay = RETRY_BASE_DELAY_MS * retryCount;
        if (delay > RETRY_MAX_DELAY_MS) {
            delay = RETRY_MAX_DELAY_MS;
        }
        nextRetryAllowedMs = System.getTimer() + delay;
    }
}
