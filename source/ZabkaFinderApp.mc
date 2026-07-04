import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

// Application entry point. Wires the single view together with its
// BehaviorDelegate (needed for the store-selection menu) in
// getInitialView().
class ZabkaFinderApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state as Dictionary?) as Void {
    }

    // onStop() is called when your application is exiting
    function onStop(state as Dictionary?) as Void {
    }

    // Return the initial view of your application here
    function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new ZabkaFinderView();
        return [ view, new ZabkaFinderDelegate(view) ];
    }

}

// Convenience accessor used elsewhere to reach the running
// application instance (e.g. from the view or a background service).
function getApp() as ZabkaFinderApp {
    return Application.getApp() as ZabkaFinderApp;
}
