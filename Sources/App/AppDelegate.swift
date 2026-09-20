import AppKit
import AuthenticationServices

/// The product name, taken from the bundle so that renaming the app only means changing `NAME` in `x`.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName

/// App entry point: owns the browser windows, builds the main menu, and opens URLs sent by other apps.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, ASWebAuthenticationSessionWebBrowserSessionHandling {
    private var windows: [BrowserWindowController] = []
    /// When the system runs short of memory, tabs hidden for a minute sleep without waiting out the half hour.
    private let memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    static func main() {
        AppPaths.migratePreviousIdentity()
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApp.setActivationPolicy(.regular)
        BrowserSettings.applyAppearance()
        NSWindow.allowsAutomaticWindowTabbing = false
        // Pages always get thumb-only overlay scrollbars. Left to the system setting, plugging in a mouse
        // switches to permanent scrollbars that sit in a boxed track. This only picks the scrollbar
        // style; pages that draw their own scrollbars, and the system's colors, are untouched.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        NSApp.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppMenu.make()
        memoryPressure.setEventHandler { [weak self] in self?.windows.forEach { $0.sleepIdleTabs(hiddenFor: 60) } }
        memoryPressure.resume()
        let authenticationSessions = ASWebAuthenticationSessionWebBrowserSessionManager.shared
        authenticationSessions.sessionHandler = self
        WebExtensions.shared.loadInstalled()
        if windows.isEmpty && !authenticationSessions.wasLaunchedByAuthenticationServices { newWindow(nil) }
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

    @discardableResult
    func openWindow(url: URL?) -> BrowserWindowController {
        let controller = BrowserWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
        windows.append(controller)
        controller.showWindow(nil)
        controller.registerWithExtensions()
        return controller
    }

    /// Tells every window that the favicons setting changed; the strips follow at once.
    func faviconsSettingChanged() {
        windows.forEach { $0.faviconsSettingChanged() }
    }

    @objc func installExtension(_ sender: Any?) {
        chooseExtension()
    }

    /// Chooses and installs a local extension, then calls `completion` after a successful load.
    func chooseExtension(completion: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.message = "Choose a WebExtension directory or ZIP archive."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await WebExtensions.shared.install(from: url)
                    completion?()
                } catch {
                    let alert = NSAlert(error: error)
                    if let window = NSApp.keyWindow {
                        alert.beginSheetModal(for: window) { _ in }
                    } else {
                        alert.runModal()
                    }
                }
            }
        }
    }

    /// Opens an authentication request in Aero and returns its callback to the originating app.
    func begin(_ request: ASWebAuthenticationSessionRequest) {
        let controller = windows.last ?? openWindow(url: nil)
        controller.openAuthentication(request)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the tab when the app that initiated authentication cancels its request.
    func cancel(_ request: ASWebAuthenticationSessionRequest) {
        windows.forEach { $0.cancelAuthentication(request) }
    }
}
