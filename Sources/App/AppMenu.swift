import AppKit

/// Builds Aero's native menu bar. Tab-number shortcuts stay on `BrowserWindow` so the Window menu
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
                .separator(),
                item("Settings…", #selector(BrowserWindowController.openSettings(_:)), ","),
                .separator(),
                item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
                item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                .separator(),
                item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
            ])
        menu(
            "File",
            [
                item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"),
                item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
                item("Open Location", #selector(BrowserWindowController.openLocation(_:)), "l"),
                .separator(),
                item("Install Extension...", #selector(AppDelegate.installExtension(_:)), ""),
                .separator(),
                item("Print", #selector(BrowserWindowController.printPage(_:)), "p"),
                .separator(),
                item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"),
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
                item("Find", #selector(BrowserWindowController.findPage(_:)), "f"),
            ])
        menu(
            "View",
            [
                item("Reload", #selector(BrowserWindowController.reloadPage(_:)), "r"),
                item("Stop", #selector(BrowserWindowController.stopLoadingPage(_:)), "."),
                .separator(),
                item("Actual Size", #selector(BrowserWindowController.resetPageZoom(_:)), "0"),
                item("Zoom In", #selector(BrowserWindowController.zoomInPage(_:)), "+"),
                item("Zoom Out", #selector(BrowserWindowController.zoomOutPage(_:)), "-"),
                .separator(),
                item("Pin or Unpin Tab", #selector(BrowserWindowController.togglePin(_:)), "d"),
                item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            ])
        menu(
            "History",
            [
                item("Back", #selector(BrowserWindowController.goBackInHistory(_:)), "["),
                item("Forward", #selector(BrowserWindowController.goForwardInHistory(_:)), "]"),
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
