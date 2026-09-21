import AppKit

/// Builds Aero's native menu bar. Tab-number shortcuts stay on `Window` so the Window menu
/// contains only window commands and the system-managed list of open windows.
enum AppMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
            if title == "Window" { NSApp.windowsMenu = menu }
        }
        func item(
            _ title: String, _ action: Selector, _ key: String,
            _ modifiers: NSEvent.ModifierFlags = .command
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        menu(
            appName,
            [
                item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
                item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), ""),
                .separator(),
                item("Settings…", #selector(WindowController.openSettings(_:)), ","),
                .separator(),
                item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
                item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                .separator(),
                item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
            ])
        menu(
            "File",
            [
                item("New Tab", #selector(WindowController.newTab(_:)), "t"),
                item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
                item("New Private Window", #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift]),
                item("Reopen Closed Tab", #selector(WindowController.reopenClosedTab(_:)), "t", [.command, .shift]),
                item("Open Location", #selector(WindowController.openLocation(_:)), "l"),
                .separator(),
                item("Install Extension...", #selector(AppDelegate.installExtension(_:)), ""),
                .separator(),
                item("Print", #selector(WindowController.printPage(_:)), "p"),
                .separator(),
                item("Close Tab", #selector(WindowController.closeTab(_:)), "w"),
                item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            ])
        menu(
            "Edit",
            [
                item("Undo", Selector(("undo:")), "z"),
                item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                item("Cut", #selector(NSText.cut(_:)), "x"),
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
                .separator(),
                item("Find", #selector(WindowController.findPage(_:)), "f"),
                .separator(),
                item("Show Spelling and Grammar", #selector(NSTextView.showGuessPanel(_:)), ":"),
                item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), ""),
            ])
        menu(
            "View",
            [
                item("Reload", #selector(WindowController.reloadPage(_:)), "r"),
                item("Stop", #selector(WindowController.stopLoadingPage(_:)), "."),
                item("Downloads", #selector(WindowController.openDownloads(_:)), "l", [.command, .option]),
                .separator(),
                item("Actual Size", #selector(WindowController.resetPageZoom(_:)), "0"),
                item("Zoom In", #selector(WindowController.zoomInPage(_:)), "+"),
                item("Zoom Out", #selector(WindowController.zoomOutPage(_:)), "-"),
                .separator(),
                item("Pin or Unpin Tab", #selector(WindowController.togglePin(_:)), ""),
                item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            ])
        menu(
            "History",
            [
                item("Back", #selector(WindowController.goBackInHistory(_:)), "["),
                item("Forward", #selector(WindowController.goForwardInHistory(_:)), "]"),
                .separator(),
                item("Show History", #selector(WindowController.openHistoryPage(_:)), "y"),
                item("Recent History", #selector(WindowController.showRecentHistory(_:)), ""),
                item("Delete Browsing Data…", #selector(WindowController.deleteBrowsingData(_:)), "\u{8}", [.command, .shift]),
            ])
        menu(
            "Bookmarks",
            [
                item("Bookmark This Page…", #selector(WindowController.bookmarkPage(_:)), "d"),
                item("Show Bookmarks", #selector(WindowController.openBookmarksPage(_:)), "b", [.command, .option]),
                item("Tab Groups", #selector(WindowController.showTabGroups(_:)), ""),
            ])
        menu(
            "Window",
            [
                item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
                .separator(),
            ])
        return main
    }
}
