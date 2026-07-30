import Toybox.Attention;
import Toybox.Lang;
import Toybox.Timer;

// Thin wrappers around the two side effects ProximityAlerts needs:
// buzzing the watch and scheduling a callback. They exist so the
// alert logic can be injected with fakes in unit tests - the state
// machine decides *when* to buzz, these classes only carry it out.
// Keeping them separate also means the untestable part is a handful
// of lines with no branching, which is exactly where bugs don't hide.

class Vibrator {

    // Short, distinct double pulse. Guarded with `has :vibrate`, as
    // Attention.vibrate isn't available on every device (and can be
    // disabled system-wide by the user).
    function vibrate() as Void {
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

// One-shot timer. Starting a new one always cancels the previous, so
// callers can't leak timers by scheduling twice.
class Scheduler {

    private var timer as Timer.Timer or Null = null;

    function start(callback as (Method() as Void), delayMs as Lang.Number) as Void {
        stop();
        timer = new Timer.Timer();
        (timer as Timer.Timer).start(callback, delayMs, false);
    }

    function stop() as Void {
        if (timer != null) {
            (timer as Timer.Timer).stop();
            timer = null;
        }
    }
}
