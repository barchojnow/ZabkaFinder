import Toybox.Lang;
import Toybox.Test;

// Unit tests for the haptic state machines. The interesting rules
// here are invisible from the outside (a latch and a hysteresis
// band), and the one that matters most - "exactly one buzz per
// approach" - can only be verified by counting vibrations. Hence the
// injected fakes: no hardware, no waiting 15 seconds for a timer.
module ProximityAlertsTest {

    // Counts buzzes instead of performing them.
    class VibratorSpy {
        var count as Lang.Number = 0;
        function vibrate() as Void {
            count += 1;
        }
    }

    // Records the scheduled callback so the test can fire it on
    // demand, and tracks stop() so we can assert cleanup.
    class SchedulerFake {
        var pending as (Method() as Void) or Null = null;
        var startCount as Lang.Number = 0;
        var stopCount as Lang.Number = 0;

        function start(callback as (Method() as Void), delayMs as Lang.Number) as Void {
            pending = callback;
            startCount += 1;
        }

        function stop() as Void {
            if (pending != null) {
                pending = null;
            }
            stopCount += 1;
        }

        // "Advance time" to the deadline.
        function fire() as Void {
            var callback = pending;
            pending = null;
            if (callback != null) {
                callback.invoke();
            }
        }
    }

    // Fixture: alerts + its fakes, plus a flag proving the timeout
    // callback reached the owner.
    class Fixture {
        var vibrator as VibratorSpy;
        var scheduler as SchedulerFake;
        var alerts as ProximityAlerts;
        var timedOut as Lang.Boolean = false;

        function initialize() {
            vibrator = new VibratorSpy();
            scheduler = new SchedulerFake();
            alerts = new ProximityAlerts(method(:onTimeout), vibrator, scheduler);
        }

        function onTimeout() as Void {
            timedOut = true;
        }
    }

    // --- arrival vibration ----------------------------------------------

    // The core rule: crossing 30 m buzzes once, and staying close
    // does not buzz again on every GPS update.
    (:test)
    function arrivalBuzzesExactlyOnce(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onDistanceUpdated(120.0f, false, false);
        f.alerts.onDistanceUpdated(25.0f, false, false);   // enter the zone
        f.alerts.onDistanceUpdated(20.0f, false, false);
        f.alerts.onDistanceUpdated(12.0f, false, false);
        f.alerts.onDistanceUpdated(28.0f, false, false);

        if (f.vibrator.count != 1) {
            logger.error("expected exactly 1 buzz, got " + f.vibrator.count);
            return false;
        }
        return true;
    }

    // GPS noise around the threshold (30 m <-> 45 m) must not
    // re-arm the latch - that's what the 50 m band is for.
    (:test)
    function jitterInsideHysteresisBandDoesNotRebuzz(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onDistanceUpdated(25.0f, false, false);   // buzz #1
        f.alerts.onDistanceUpdated(45.0f, false, false);   // above 30, below 50
        f.alerts.onDistanceUpdated(24.0f, false, false);   // back in the zone
        f.alerts.onDistanceUpdated(48.0f, false, false);
        f.alerts.onDistanceUpdated(22.0f, false, false);

        if (f.vibrator.count != 1) {
            logger.error("hysteresis broken: " + f.vibrator.count + " buzzes");
            return false;
        }
        return true;
    }

    // Walking properly away (past 50 m) and coming back is a new
    // approach and should buzz again.
    (:test)
    function reArmsAfterLeavingHysteresisBand(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onDistanceUpdated(25.0f, false, false);   // buzz #1
        f.alerts.onDistanceUpdated(80.0f, false, false);   // clearly gone
        f.alerts.onDistanceUpdated(20.0f, false, false);   // buzz #2

        if (f.vibrator.count != 2) {
            logger.error("expected 2 buzzes across two approaches, got "
                + f.vibrator.count);
            return false;
        }
        return true;
    }

    // Picking a different store is a new approach even without
    // leaving the zone.
    (:test)
    function newTargetReArmsArrivalBuzz(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onDistanceUpdated(25.0f, false, false);   // buzz #1
        f.alerts.onNewTarget();
        f.alerts.onDistanceUpdated(28.0f, false, false);   // buzz #2

        if (f.vibrator.count != 2) {
            logger.error("expected re-arm on new target, got " + f.vibrator.count);
            return false;
        }
        return true;
    }

    // --- walking-away prompt --------------------------------------------

    // Baseline is the MINIMUM distance reached, not the distance at
    // pick time - so approaching then drifting away still triggers.
    (:test)
    function awayPromptTriggersAboveMinimumNotStart(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(500.0f, true, false);   // start far
        f.alerts.onDistanceUpdated(200.0f, true, false);   // walk closer: new minimum
        f.alerts.onDistanceUpdated(260.0f, true, false);   // +60 over minimum: not yet

        if (f.alerts.isAwayActive()) {
            logger.error("fired too early (+60 m)");
            return false;
        }

        f.alerts.onDistanceUpdated(280.0f, true, false);   // +80 over minimum
        if (!f.alerts.isAwayActive()) {
            logger.error("should have fired at +80 m over the minimum");
            return false;
        }
        if (f.scheduler.startCount != 1) {
            logger.error("prompt must schedule exactly one timeout, got "
                + f.scheduler.startCount);
            return false;
        }
        return true;
    }

    // Auto-selected targets follow the nearest store silently; the
    // prompt is only for choices the user made by hand.
    (:test)
    function awayPromptIgnoresAutomaticTarget(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onDistanceUpdated(200.0f, false, false);
        f.alerts.onDistanceUpdated(400.0f, false, false);  // +200, but automatic

        if (f.alerts.isAwayActive()) {
            logger.error("prompt must not fire for automatic targets");
            return false;
        }
        return true;
    }

    // While the store menu covers the view, the prompt would fight
    // the user's own interaction.
    (:test)
    function awayPromptSuppressedWhileMenuOpen(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, true);
        f.alerts.onDistanceUpdated(300.0f, true, true);    // +200 with menu open

        if (f.alerts.isAwayActive()) {
            logger.error("prompt must stay silent while the menu is open");
            return false;
        }
        return true;
    }

    // Timeout: state clears, the owner is notified (it retargets to
    // the nearest store) and the event ends with a buzz.
    (:test)
    function timeoutNotifiesOwnerAndClearsState(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);
        f.alerts.onDistanceUpdated(200.0f, true, false);   // prompt on
        var buzzesBefore = f.vibrator.count;

        f.scheduler.fire();                                 // 15 s later

        if (f.alerts.isAwayActive()) {
            logger.error("prompt still active after timeout");
            return false;
        }
        if (!f.timedOut) {
            logger.error("owner callback was not invoked");
            return false;
        }
        if (f.vibrator.count != buzzesBefore + 1) {
            logger.error("timeout should close the event with one buzz");
            return false;
        }
        return true;
    }

    // Tapping "keep going" stops the timer and resets the baseline to
    // where the user is now, so drifting further re-triggers later.
    (:test)
    function dismissStopsTimerAndReArmsFromCurrentDistance(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);
        f.alerts.onDistanceUpdated(200.0f, true, false);   // prompt on

        f.alerts.dismissAway(200.0f);
        if (f.alerts.isAwayActive()) {
            logger.error("dismiss should end the prompt");
            return false;
        }
        if (f.scheduler.stopCount < 1) {
            logger.error("dismiss must cancel the scheduled timeout");
            return false;
        }

        // New baseline is 200 m, so 260 m is only +60: still quiet.
        f.alerts.onDistanceUpdated(260.0f, true, false);
        if (f.alerts.isAwayActive()) {
            logger.error("baseline was not reset to the dismiss distance");
            return false;
        }
        // ...but 290 m is +90 and must trigger again.
        f.alerts.onDistanceUpdated(290.0f, true, false);
        if (!f.alerts.isAwayActive()) {
            logger.error("prompt should be able to fire again later");
            return false;
        }
        return true;
    }

    // Picking a store from the menu during a prompt ends it, and the
    // fresh baseline comes from the next distance update.
    (:test)
    function manualPickClearsPendingPrompt(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);
        f.alerts.onDistanceUpdated(200.0f, true, false);   // prompt on

        f.alerts.onManualPick();                            // user picks another store
        if (f.alerts.isAwayActive()) {
            logger.error("manual pick should clear the prompt");
            return false;
        }
        return true;
    }

    // onHide() teardown: no timer may outlive the view.
    (:test)
    function resetCancelsEverything(logger as Test.Logger) as Lang.Boolean {
        var f = new Fixture();
        f.alerts.onManualPick();
        f.alerts.onDistanceUpdated(100.0f, true, false);
        f.alerts.onDistanceUpdated(200.0f, true, false);   // prompt on

        f.alerts.reset();
        if (f.alerts.isAwayActive() || f.scheduler.stopCount < 1) {
            logger.error("reset must cancel the prompt and its timer");
            return false;
        }
        return true;
    }
}
