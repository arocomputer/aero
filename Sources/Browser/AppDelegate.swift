import AppKit

/// The product name, taken from the bundle so that renaming the app only means changing `NAME` in the Makefile.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName

/// App entry point: owns the browser windows, builds the main menu, and opens URLs sent by other apps.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [BrowserWindowController] = []

    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        // Pages always get thumb-only overlay scrollbars. Left to the system setting, plugging in a mouse
        // switches to permanent scrollbars that sit in a boxed track. This only picks the scrollbar
        // style; pages that draw their own scrollbars, and the system's colors, are untouched.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        NSApp.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        if windows.isEmpty { newWindow(nil) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let front = windows.last { front.openExternal(url) } else { openWindow(url: url) }
        }
        windows.last?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { newWindow(nil) }
        return true
    }

    @objc func newWindow(_ sender: Any?) { openWindow(url: nil) }

    private func openWindow(url: URL?) {
        let controller = BrowserWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
        windows.append(controller)
        controller.showWindow(nil)
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
            if title == "Window" { NSApp.windowsMenu = menu }
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0)
            -> NSMenuItem
        {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            return item
        }

        menu(
            appName,
            [
                item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
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
                item("New Window", #selector(newWindow(_:)), "n"),
                item("Open Location", #selector(BrowserWindowController.openLocation(_:)), "l"),
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
                item("Show Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "}"),
                item("Show Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "{"),
                .separator(),
            ]
                + (1...9).map {
                    item($0 == 9 ? "Last Tab" : "Tab \($0)", #selector(BrowserWindowController.selectTabByNumber(_:)), "\($0)", tag: $0)
                })
        return main
    }
}
