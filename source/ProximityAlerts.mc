import Toybox.Attention;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// Haptic feedback state machines: the one-shot arrival vibration
// (with hysteresis) and the "walking away from a manually picked
// store" prompt with its 15-second decision timer. Owns no UI - the
// view draws the prompt and decides what happens on timeout via the
// callback passed to the constructor.
class ProximityAlerts {

    // Below this distance the arrival vibration fires (the view also
    // uses this threshold for the green color / pulsing dot).
    const CLOSE_DISTANCE_M = 30.0;
    // The vibration re-arms only after walking back out past this
    // distance (hysteresis), so GPS jitter around the 30 m line
    // can't retrigger it over and over.
    const VIBE_REARM_DISTANCE_M = 50.0;
    // The away-event fires once the distance to the chosen store
    // grows this much above the minimum reached since it was picked
    // (GPS noise won't produce a 75 m monotonic drift).
    const AWAY_TRIGGER_DELTA_M = 75.0;
    // How long the prompt waits for a decision before the timeout
    // callback fires (the view then auto-switches to the nearest).
    const AWAY_PROMPT_TIMEOUT_MS = 15000;

    // One-shot latch for the arrival vibration.
    private var hasVibrated as Lang.Boolean = false;

    // Smallest distance to the manual target since it was picked.
    private var minManualDistance as Lang.Float = 1000000.0f;
    private var awayActive as Lang.Boolean = false;
    private var awayDeadlineMs as Lang.Number = 0;
    private var awayTimer as Timer.Timer or Null = null;

    // Invoked when the prompt times out without a decision.
    private var timeoutCallback as (Method() as Void);

    function initialize(onTimeout as (Method() as Void)) {
        timeoutCallback = onTimeout;
    }

    // Called on every GPS-driven distance update (never from redraws,
    // so nothing here can fire once per frame). suppressAway blocks
    // the away-prompt while the store menu covers the view.
    function onDistanceUpdated(distance as Lang.Float, manualTarget as Lang.Boolean,
                               suppressAway as Lang.Boolean) as Void {
        // Arrival vibration with re-arm hysteresis.
        if (distance <= CLOSE_DISTANCE_M) {
            if (!hasVibrated) {
                hasVibrated = true;
                vibrateShort();
            }
        } else if (distance > VIBE_REARM_DISTANCE_M) {
            hasVibrated = false;
        }

        // Walking-away detection, only for manually picked targets.
        if (!manualTarget || awayActive || suppressAway) {
            return;
        }
        if (distance < minManualDistance) {
            minManualDistance = distance;
        } else if (distance > minManualDistance + AWAY_TRIGGER_DELTA_M) {
            startAwayPrompt();
        }
    }

    // A new navigation target: re-arm the arrival vibration.
    function onNewTarget() as Void {
        hasVibrated = false;
    }

    // An explicit pick from the menu: end any pending prompt and
    // reset the baseline ABOVE any plausible distance, so the next
    // distance update lowers it to the real one.
    function onManualPick() as Void {
        stopAwayTimer();
        awayActive = false;
        minManualDistance = 1000000.0f;
    }

    function isAwayActive() as Lang.Boolean {
        return awayActive;
    }

    // Seconds left on the prompt countdown, for drawing.
    function awayRemainingSeconds() as Lang.Number {
        var remaining = (awayDeadlineMs - System.getTimer()) / 1000;
        return remaining < 0 ? 0 : remaining;
    }

    // User chose to stay with the manual target: end the event with a
    // vibration and reset the baseline to the current distance, so
    // walking away *again* re-triggers it later.
    function dismissAway(currentDistance as Lang.Float) as Void {
        if (!awayActive) {
            return;
        }
        stopAwayTimer();
        awayActive = false;
        minManualDistance = currentDistance;
        vibrateShort();
    }

    // Full teardown for View.onHide().
    function reset() as Void {
        stopAwayTimer();
        awayActive = false;
    }

    private function startAwayPrompt() as Void {
        awayActive = true;
        awayDeadlineMs = System.getTimer() + AWAY_PROMPT_TIMEOUT_MS;
        vibrateShort();
        awayTimer = new Timer.Timer();
        (awayTimer as Timer.Timer).start(method(:onAwayTimerFired), AWAY_PROMPT_TIMEOUT_MS, false);
        WatchUi.requestUpdate();
    }

    private function stopAwayTimer() as Void {
        if (awayTimer != null) {
            (awayTimer as Timer.Timer).stop();
            awayTimer = null;
        }
    }

    // Timer callback: end the event audibly and let the owner decide
    // what to retarget to.
    function onAwayTimerFired() as Void {
        awayTimer = null;
        if (!awayActive) {
            return;
        }
        awayActive = false;
        vibrateShort();
        timeoutCallback.invoke();
    }

    // Short, distinct double pulse. Guarded with `has :vibrate`, as
    // Attention.vibrate isn't available on every device (and can be
    // disabled system-wide by the user).
    function vibrateShort() as Void {
        if (Attention has :vibrate) {
            var pattern = [
                new Attention.VibeProfile(75, 250),  // 75% strength, 250 ms
                new Attention.VibeProfile(0, 100),   // pause
                new Attention.VibeProfile(75, 250)
            ] as Lang.Array<Attention.VibeProfile>;
            Attention.vibrate(pattern);
        }
    }
}
