import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

// Application entry point. A Connect IQ "widget" only has a single
// view, defined below in getInitialView().
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
        return [ new ZabkaFinderView() ];
    }

}

// Convenience accessor used elsewhere to reach the running
// application instance (e.g. from the view or a background service).
function getApp() as ZabkaFinderApp {
    return Application.getApp() as ZabkaFinderApp;
}
