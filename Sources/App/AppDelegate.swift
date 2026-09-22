import AppKit
import AuthenticationServices
import WebKit

/// The product name, taken from the bundle so that renaming the app only means changing `NAME` in `x`.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName

/// App entry point: owns the browser windows, builds the main menu, and opens URLs sent by other apps.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, ASWebAuthenticationSessionWebBrowserSessionHandling, NSMenuItemValidation {
    private var windows: [WindowController] = []
    private var authenticationOnlyLaunch = false
    private var sessionSave: DispatchWorkItem?
    private var launchFinished = false
    private var endingDownloads = false
    private var protectionTimer: Timer?
    /// When the system runs short of memory, tabs hidden for a minute sleep without waiting out the half hour.
    private let memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    static func main() {
        AppPaths.migratePreviousIdentity()
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        // The debug bundle is marked LSUIElement, which keeps it out of the Dock and the app switcher.
        // The menu bar goes with it, macOS offering no way to drop one and keep the other, though the
        // menu's shortcuts still work. The shipping Info.plist carries no such key: Aero is an ordinary app.
        let isAccessory = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
        NSApp.setActivationPolicy(isAccessory ? .accessory : .regular)
        Settings.applyAppearance()
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
        authenticationOnlyLaunch = authenticationSessions.wasLaunchedByAuthenticationServices
        authenticationSessions.sessionHandler = self
        Task { [weak self] in
            await WebExtensions.shared.loadInstalled()
            guard let self, !authenticationOnlyLaunch, let context = WebExtensions.shared.newTabContext,
                let url = context.overrideNewTabPageURL
            else { return }
            for window in windows where !window.isPrivate {
                for blank in window.tabs.filter({ $0.isBlank && $0.omniboxDraft.isEmpty }) {
                    window.openTab(url: url, configuration: context.webViewConfiguration, inBackground: blank !== window.active)
                        .isNewTabOverride = true
                    window.close(blank)
                }
            }
        }
        if !authenticationSessions.wasLaunchedByAuthenticationServices, Settings.restoresSession {
            for saved in SavedSession.load() {
                let window = openWindow(url: saved.tabs[0].url)
                window.active?.groupName = saved.tabs[0].group
                for entry in saved.tabs.dropFirst() {
                    window.openTab(url: entry.url, inBackground: true).groupName = entry.group
                }
                let ordinary = window.tabs.filter { !$0.isPinned }
                if ordinary.indices.contains(saved.selected) { window.select(ordinary[saved.selected]) }
                window.collapsedGroups = Set(saved.collapsedGroups ?? [])
                if let frame = saved.frame, let native = window.window {
                    native.setFrame(native.constrainFrameRect(NSRectFromString(frame), to: NSScreen.main), display: true)
                }
                window.updateStrip()
            }
        }
        if !authenticationOnlyLaunch, Settings.startupMode == "pages", let first = Settings.startupPages.first {
            if let window = windows.last(where: { !$0.isPrivate }) {
                for url in Settings.startupPages { window.openTab(url: url, inBackground: true) }
            } else {
                let window = openWindow(url: first)
                for url in Settings.startupPages.dropFirst() { window.openTab(url: url, inBackground: true) }
            }
        }
        if windows.isEmpty && !authenticationSessions.wasLaunchedByAuthenticationServices { newWindow(nil) }
        launchFinished = true
        if !authenticationOnlyLaunch { Updates.shared.start() }
        Task { await SecureDNS.shared.load() }
        if !authenticationOnlyLaunch {
            Task { await ProtectionUpdates.shared.checkIfDue() }
            protectionTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
                Task { @MainActor in await ProtectionUpdates.shared.checkIfDue() }
            }
            protectionTimer?.tolerance = 600
        }
        scheduleSessionSave()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionSave?.cancel()
        saveSession()
        for context in WebExtensions.shared.contexts { WebExtensions.shared.savePermissions(context) }
    }

    /// Gives WebKit time to produce resume data before the process exits. Private partial files are discarded.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !endingDownloads else { return .terminateLater }
        endingDownloads = true
        let group = DispatchGroup()
        group.enter()
        Downloads.shared.pauseAll { group.leave() }
        for window in windows where window.isPrivate {
            group.enter()
            window.downloads.endPrivateSession { group.leave() }
        }
        group.notify(queue: .main) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Coalesces window changes and avoids writing snapshots when restoration is disabled.
    func scheduleSessionSave() {
        guard launchFinished, Settings.restoresSession, sessionSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.sessionSave = nil
            self?.saveSession()
        }
        sessionSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func saveSession() {
        guard Settings.restoresSession else { return }
        let session = windows.filter { !$0.isPrivate && $0.extensionWindowType == .normal }.compactMap {
            controller -> SavedSession.WindowState? in
            let tabs = controller.tabs.filter { $0.recordsActivity && !$0.isPinned && AddressInput.isWeb($0.url) }
            guard !tabs.isEmpty else { return nil }
            return SavedSession.WindowState(
                tabs: tabs.compactMap { tab in tab.url.map { SavedSession.TabState(url: $0, group: tab.groupName) } },
                selected: tabs.firstIndex { $0 === controller.active } ?? 0,
                frame: controller.window.map { NSStringFromRect($0.frame) },
                collapsedGroups: controller.collapsedGroups.intersection(Set(tabs.compactMap(\.groupName))).sorted())
        }
        // A temporary authentication-only launch must not replace the saved browsing session.
        if authenticationOnlyLaunch && session.isEmpty { return }
        SavedSession.saveWindows(session)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let front = windows.last(where: { !$0.isPrivate && $0.extensionWindowType == .normal }) {
                front.openExternal(url)
                front.window?.makeKeyAndOrderFront(nil)
            } else {
                openWindow(url: url)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { newWindow(nil) }
        return true
    }

    @objc func newWindow(_ sender: Any?) { openWindow(url: nil) }
    @MainActor @objc func checkForUpdates(_ sender: Any?) { Updates.shared.check() }
    @MainActor func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates(_:)) { return Updates.shared.canCheck }
        return true
    }
    @objc func newPrivateWindow(_ sender: Any?) { openWindow(url: nil, isPrivate: true) }
    @MainActor @objc func reopenClosedTab(_ sender: Any?) {
        guard !ClosedTabs.entries.isEmpty else { return }
        let controller = windows.last(where: { !$0.isPrivate }) ?? openWindow(url: nil)
        controller.reopenClosedTab(nil)
    }

    /// Registers tabs before presentation; extension windows can omit pins and transfer live tabs without taking focus.
    /// `origin`, when given, places the window before it is shown, so a tab torn out of a strip does not flash at its center.
    @discardableResult
    func openWindow(
        url: URL?, isPrivate: Bool = false, configuration: WKWebViewConfiguration? = nil, windowType: WKWebExtension.WindowType = .normal,
        restorePins: Bool = true, initialTabs: [Tab] = [], focused: Bool = true, origin: NSPoint? = nil
    ) -> WindowController {
        let controller = WindowController(
            url: url, isPrivate: isPrivate, configuration: configuration, windowType: windowType,
            restorePins: restorePins, startsEmpty: !initialTabs.isEmpty && url == nil)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
            self?.scheduleSessionSave()
        }
        windows.append(controller)
        controller.registerWithExtensions()
        for (index, tab) in initialTabs.enumerated() { controller.transfer(tab, to: index) }
        if let origin { controller.window?.setFrameOrigin(origin) }
        if focused { controller.window?.makeKeyAndOrderFront(nil) } else { controller.window?.orderBack(nil) }
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
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
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
        let controller = windows.last(where: { !$0.isPrivate }) ?? openWindow(url: nil)
        controller.openAuthentication(request)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the tab when the app that initiated authentication cancels its request.
    func cancel(_ request: ASWebAuthenticationSessionRequest) {
        windows.forEach { $0.cancelAuthentication(request) }
    }
}
