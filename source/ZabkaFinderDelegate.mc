import Toybox.Lang;
import Toybox.WatchUi;

// KROK 4: input handling for the main view. A tap on the screen (or
// the START/select button on 5-button devices like Fenix/Forerunner)
// opens a native Menu2 listing the 5 nearest stores; picking one
// retargets the arrow on the main screen.
class ZabkaFinderDelegate extends WatchUi.BehaviorDelegate {

    const MENU_MAX_ITEMS = 5;

    private var view as ZabkaFinderView;
    private var strMenuTitle as Lang.String;
    private var strStoreFallback as Lang.String;

    function initialize(view as ZabkaFinderView) {
        BehaviorDelegate.initialize();
        self.view = view;
        strMenuTitle = WatchUi.loadResource(Rez.Strings.MenuTitle) as Lang.String;
        strStoreFallback = WatchUi.loadResource(Rez.Strings.StoreFallbackName) as Lang.String;
    }

    // On touch devices a screen tap maps to the select behavior; on
    // button devices it's the START key - one handler covers both.
    function onSelect() as Lang.Boolean {
        // While the "walking away" prompt is showing, tap/START means
        // "keep going to my chosen store" instead of opening the menu.
        if (view.isAwayPromptActive()) {
            view.dismissAwayPrompt();
            return true;
        }
        return openStoreMenu();
    }

    // MENU (button hold on Fenix/Forerunner, long screen press on
    // touch devices) always leads to the store list - during the
    // away-prompt this is the "pick a different store" path.
    function onMenu() as Lang.Boolean {
        if (view.isAwayPromptActive()) {
            view.dismissAwayPrompt();
        }
        return openStoreMenu();
    }

    private function openStoreMenu() as Lang.Boolean {
        // Opening the menu is a natural moment to refresh a stale
        // store list. The response is asynchronous, so it benefits
        // the *next* open, but this menu still shows re-sorted,
        // distance-fresh entries from the current list.
        view.maybeResearch();

        var stores = view.getNearestStores(MENU_MAX_ITEMS);
        if (stores.size() == 0) {
            // Nothing to choose from yet (no fix / no results):
            // let the system handle the event normally.
            return false;
        }

        var menu = new WatchUi.Menu2({ :title => strMenuTitle });
        for (var i = 0; i < stores.size(); i++) {
            var s = stores[i] as Lang.Dictionary;
            var dist = s[:dist] as Lang.Double;
            var addr = (s[:addr] != null) ? s[:addr] as Lang.String : strStoreFallback;
            // The item id is simply the index into the view's sorted
            // store list, which selectStore() maps back to coordinates.
            menu.addItem(new WatchUi.MenuItem(
                addr,                             // title: street + number
                dist.format("%.0f") + " m",       // subtitle: live distance
                i,                                // id
                {}
            ));
        }

        // Keep GPS/sensors alive while the menu covers the view, so
        // distances stay fresh and there's no fix re-acquisition
        // after returning to the arrow screen.
        view.setMenuOpen(true);
        WatchUi.pushView(menu, new StoreMenuDelegate(view), WatchUi.SLIDE_UP);
        return true;
    }
}

// Handles selection inside the Menu2 store list.
class StoreMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var view as ZabkaFinderView;

    function initialize(view as ZabkaFinderView) {
        Menu2InputDelegate.initialize();
        self.view = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        // Update the navigation target, then return to the arrow
        // screen, which now guides to the chosen store.
        view.selectStore(item.getId() as Lang.Number);
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
