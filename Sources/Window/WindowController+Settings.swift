import AppKit
import WebKit

/// The settings page's privileged actions, which arrive as `aero://settings/action/…` links.
extension WindowController {
    /// A direct menu command with explicit data categories and a time range, before anything is deleted.
    @objc func deleteBrowsingData(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete browsing data?"
        alert.informativeText = "Choose what to remove. Deleting cookies and website data may sign you out. Open pages can create new data."
        alert.addButton(withTitle: "Delete Data")
        alert.addButton(withTitle: "Cancel")
        let controls = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 110))
        let label = NSTextField(labelWithString: "Time range")
        label.frame = NSRect(x: 0, y: 80, width: 90, height: 20)
        let range = NSPopUpButton(frame: NSRect(x: 100, y: 76, width: 260, height: 28))
        range.addItems(withTitles: ["Last hour", "Last 24 hours", "Last 7 days", "All time"])
        range.selectItem(at: 3)
        range.setAccessibilityLabel("Time range")
        let history = NSButton(checkboxWithTitle: "Browsing history and all saved site icons", target: nil, action: nil)
        history.state = .on
        history.frame = NSRect(x: 0, y: 42, width: 360, height: 24)
        let sites = NSButton(checkboxWithTitle: "Cookies and website data", target: nil, action: nil)
        sites.frame = NSRect(x: 0, y: 10, width: 360, height: 24)
        [label, range, history, sites].forEach(controls.addSubview)
        alert.accessoryView = controls
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                let date = Self.clearDate(["hour", "day", "week", "all"][range.indexOfSelectedItem])
            else { return }
            if history.state == .on {
                History.shared.clear(since: date)
                Favicons.shared.clear()
                SavedSession.clear()
                ClosedTabs.clear()
            }
            if sites.state == .on {
                WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: date) {}
            }
        }
    }

    /// Opens Aero's local settings page from either the application menu or browser menu.
    @objc func openSettings(_ sender: Any?) {
        if let existing = tabs.first(where: { $0.url?.scheme == "aero" && $0.url?.host == "settings" }) {
            select(existing)
            existing.webView.reload()
        } else {
            openTab(url: SettingsPage.pageURL)
        }
    }

    /// Performs privileged settings-page actions after WebKit verifies they came from an Aero page.
    func handleSettingsAction(_ url: URL, from tab: Tab) {
        let action = String(url.path.dropFirst("/action/".count))
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "value" })?.value
        switch action {
        case "check-updates": Updates.shared.check()
        case "update-protection":
            Task { @MainActor in
                do { try await ProtectionUpdates.shared.check() } catch { self.showSettingsError(error) }
                tab.webView.reload()
            }
        case "secure-dns": configureSecureDNS()
        case "edit-site": editSite()
        case "network-settings": NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
        case "startup-mode":
            guard let value, ["blank", "pages", "restore"].contains(value) else { return }
            Settings.startupMode = value
            (NSApp.delegate as? AppDelegate)?.scheduleSessionSave()
            tab.webView.reload()
        case "web-security":
            guard let value, let mode = WebSecurityMode(rawValue: value), WebSecurityMode.available.contains(mode) else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "WebSecurityMode")
            tab.webView.reload()
        case "startup-pages": editAddressList(key: "StartupPages", title: "Startup pages")
        case "use-current-pages":
            UserDefaults.standard.set(
                tabs.filter { $0.recordsActivity && AddressInput.isWeb($0.url) }.compactMap { $0.url?.absoluteString },
                forKey: "StartupPages")
            tab.webView.reload()
        case "sleep-exceptions": editAddressList(key: "NeverSleepSites", title: "Keep these sites awake")
        case "sleep-minutes":
            guard let value, let minutes = Int(value), [5, 15, 30, 60, 120].contains(minutes) else { return }
            UserDefaults.standard.set(minutes, forKey: "SleepMinutes")
            tab.webView.reload()
        case "autoplay":
            guard let value, ["allow", "sound", "block"].contains(value) else { return }
            UserDefaults.standard.set(value, forKey: "Autoplay")
            tab.webView.reload()
        case "minimum-font":
            guard let value, let size = Int(value), [0, 9, 12, 14, 16, 18, 20].contains(size) else { return }
            UserDefaults.standard.set(size, forKey: "MinimumFontSize")
            for controller in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
                controller.tabs.forEach { $0.refreshPreferences() }
            }
            tab.webView.reload()
        case "reset-site-zoom":
            guard let value else { return }
            var zooms = Settings.siteZooms
            zooms.removeValue(forKey: value)
            UserDefaults.standard.set(zooms, forKey: "SiteZooms")
            for controller in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
                controller.tabs.forEach { $0.resetSavedZoom(for: value) }
            }
            tab.webView.reload()
        case "language":
            guard let value, PrivacyPages.languageChoices.contains(where: { $0.0 == value }) else { return }
            UserDefaults.standard.set(value, forKey: "PreferredLanguage")
            if value == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([value], forKey: "AppleLanguages")
            }
            tab.webView.reload()
        case "keyboard-settings": NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        case "reset-preferences":
            confirmSettingsChange(
                title: "Reset browser preferences?",
                message:
                    "Appearance, search, startup, downloads and accessibility preferences return to their defaults. Bookmarks, history, extensions and website decisions are kept.",
                button: "Reset"
            ) {
                Settings.resetPreferences()
                for controller in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
                    controller.tabs.forEach { $0.refreshPreferences() }
                }
                tab.webView.reload()
            }
        case "reset-site-policies":
            confirmSettingsChange(
                title: "Reset website permissions?",
                message:
                    "Website rules return to their defaults. Camera and microphone access stops; pages using location reload. Cookies and stored data are kept.",
                button: "Reset"
            ) {
                for feature in SitePolicy.Feature.allCases {
                    for prefix in ["SitePolicy.", "SiteDefault.", "BlockedSitePermissions."] {
                        UserDefaults.standard.removeObject(forKey: prefix + feature.rawValue)
                    }
                }
                for controller in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
                    controller.tabs.forEach { $0.resetPermissions() }
                }
                tab.webView.reload()
            }
        case "disable-extensions":
            confirmSettingsChange(
                title: "Disable all extensions?", message: "Extensions stay installed and can be enabled individually later.",
                button: "Disable"
            ) {
                do { try WebExtensions.shared.disableAll() } catch { self.showSettingsError(error) }
                tab.webView.reload()
            }
        case "edit-search":
            editSearchEngine(value.flatMap(UUID.init(uuidString:)).flatMap { id in CustomSearch.engines.first { $0.id == id } })
        case "open-passwords":
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") { NSWorkspace.shared.open(app) }
        case "site-policy":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let key = query.first(where: { $0.name == "feature" })?.value,
                let feature = SitePolicy.Feature(rawValue: key), let value
            else { return }
            var changedOrigin: String?
            if let rawOrigin = query.first(where: { $0.name == "origin" })?.value {
                guard let site = URL(string: rawOrigin), let origin = BrowsingSecurity.origin(site) else { return }
                changedOrigin = origin
                guard value == "default" || SitePolicy.Decision(rawValue: value) != nil else { return }
                SitePolicy.set(SitePolicy.Decision(rawValue: value), feature: feature, origin: origin)
            } else if let decision = SitePolicy.Decision(rawValue: value) {
                SitePolicy.setDefault(decision, for: feature)
            }
            for controller in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
                for page in controller.tabs {
                    if page.recordsActivity, let origin = changedOrigin, let site = URL(string: origin) {
                        page.clearTemporaryPolicy(feature, at: site)
                    }
                    page.applyPolicyChanges(changed: feature, at: changedOrigin)
                }
            }
            tab.webView.reload()
        case "privacy-setting":
            let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value
            guard let key,
                [
                    "HTTPSFirst", "FraudWarnings", "BlockCookies", "ExtensionArtwork", "RemoteSuggestions", "SleepTabs", "TabFocusesLinks",
                    "GlobalPrivacyControl", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "TrackerBlocking",
                    "ProtectionListAutomaticUpdates",
                ].contains(key), let value, ["on", "off"].contains(value)
            else { return }
            if key == "SUEnableAutomaticChecks" { Updates.shared.setAutomaticChecks(value == "on") }
            if key == "SUAutomaticallyUpdate" { Updates.shared.setAutomaticDownloads(value == "on") }
            UserDefaults.standard.set(value == "on", forKey: key)
            if key == "TrackerBlocking" {
                Task { @MainActor in
                    do {
                        for controller in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
                            for page in controller.tabs {
                                try await TrackerProtection.shared.prepare(page.webView.configuration.userContentController)
                            }
                        }
                    } catch { self.showSettingsError(error) }
                }
            }
            if key == "BlockCookies" { WKWebsiteDataStore.default().httpCookieStore.setCookiePolicy(value == "on" ? .disallow : .allow) {} }
            for controller in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
                for page in controller.tabs {
                    page.refreshPreferences()
                }
            }
            tab.webView.reload()
        case "restore-session":
            guard let value, ["on", "off"].contains(value) else { return }
            Settings.restoresSession = value == "on"
            tab.webView.reload()
        case "ask-downloads":
            guard let value, ["on", "off"].contains(value) else { return }
            Settings.asksDownloadDestination = value == "on"
            tab.webView.reload()
        case "default-zoom":
            guard let value, let zoom = Int(value), Settings.zoomLevels.contains(zoom) else { return }
            Settings.defaultZoom = zoom
            tab.webView.reload()
        case "history-retention":
            guard let value, let days = Int(value), [-1, 0, 30, 90].contains(days) else { return }
            let reducing = days != 0 && (Settings.historyDays == 0 || days < Settings.historyDays)
            let apply = {
                Settings.historyDays = days
                History.shared.prune()
                if reducing {
                    Favicons.shared.clear()
                    (NSApp.delegate as? AppDelegate)?.faviconsSettingChanged()
                }
                tab.webView.reload()
            }
            if reducing {
                confirmSettingsChange(
                    title: "Reduce saved history?",
                    message: "Addresses outside the selected period and all saved site icons will be removed. This cannot be undone.",
                    button: "Change History", onCancel: { tab.webView.reload() }, action: apply)
            } else {
                apply()
            }
        case "remove-tracker-exception":
            guard let value, TrackerProtection.shared.exceptions.contains(value), let site = URL(string: "https://\(value)/") else {
                return
            }
            Task { @MainActor in
                do {
                    try await TrackerProtection.shared.setEnabled(true, for: site)
                    for controller in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
                        for page in controller.tabs where page.url?.host == site.host { page.reload() }
                    }
                    tab.webView.reload()
                } catch { showSettingsError(error) }
            }
        case "remove-permission":
            let kindValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "kind" }?.value
            guard let value, let site = URL(string: value), let kindValue, let kind = SitePermissions.Kind(rawValue: kindValue) else {
                return
            }
            SitePermissions.setBlocked(false, kind: kind, at: site)
            tab.webView.reload()
        case "manage-website-data":
            openTab(url: URL(string: "aero://site-data")!)
        case "clear-cookies", "clear-cache", "clear-storage":
            guard let date = Self.clearDate(value) else { return }
            let caches: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
            let types: Set<String> =
                action == "clear-cache"
                ? caches
                : action == "clear-cookies"
                    ? [WKWebsiteDataTypeCookies]
                    : WKWebsiteDataStore.allWebsiteDataTypes().subtracting(caches).subtracting([WKWebsiteDataTypeCookies])
            confirmSettingsChange(
                title: "Clear selected browsing data?",
                message: action == "clear-cache"
                    ? "Cached resources in the selected period will be removed. Websites may need to download files again."
                    : "Selected data in the chosen period will be removed. This may sign you out or remove offline website data.",
                button: "Clear Data"
            ) {
                tab.webView.configuration.websiteDataStore.removeData(ofTypes: types, modifiedSince: date) { tab.webView.reload() }
            }
        case "allow-passkeys":
            Passkeys.requestAccess { tab.webView.reload() }
        case "appearance":
            guard let value, let appearance = Appearance(rawValue: value) else { return }
            Settings.appearance = appearance
            tab.webView.reload()
        case "favicons":
            guard let value, ["on", "off"].contains(value) else { return }
            Settings.showsFavicons = value == "on"
            (NSApp.delegate as? AppDelegate)?.faviconsSettingChanged()
            tab.webView.reload()
        case "search-engine":
            guard let value else { return }
            if value.hasPrefix("custom:"), let engine = CustomSearch.engines.first(where: { "custom:" + $0.id.uuidString == value }) {
                UserDefaults.standard.set(engine.id.uuidString, forKey: "CustomSearchDefault")
            } else if let engine = SearchEngine(rawValue: value) {
                Settings.searchEngine = engine
                UserDefaults.standard.removeObject(forKey: "CustomSearchDefault")
            }
            tab.webView.reload()
        case "choose-downloads":
            chooseDownloadDirectory(for: tab)
        case "show-downloads":
            NSWorkspace.shared.open(Settings.downloadDirectory)
        case "clear-history":
            guard let date = Self.clearDate(value) else { return }
            confirmSettingsChange(
                title: "Clear browsing history?",
                message: "Remove addresses visited in the selected period and all saved site icons. Cookies and sign-ins will be kept.",
                button: "Clear History"
            ) {
                History.shared.clear(since: date)
                Favicons.shared.clear()
                SavedSession.clear()
                ClosedTabs.clear()
                tab.webView.reload()
            }
        case "clear-website-data":
            guard let date = Self.clearDate(value) else { return }
            confirmSettingsChange(
                title: "Clear website data?",
                message: "Remove cookies, caches and storage modified in the selected period. This may sign you out and cannot be undone.",
                button: "Clear Website Data"
            ) {
                let store = WKWebsiteDataStore.default()
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: date) {
                    tab.webView.reload()
                }
            }
        case "extensions":
            openTab(url: ExtensionCatalog.pageURL)
        case "make-default":
            makeDefaultBrowser(for: tab)
        default:
            break
        }
    }

    /// Accepts only the time ranges offered by the bundled settings page.
    private static func clearDate(_ value: String?) -> Date? {
        switch value ?? "all" {
        case "all": .distantPast
        case "hour": Date().addingTimeInterval(-3600)
        case "day": Date().addingTimeInterval(-86_400)
        case "week": Date().addingTimeInterval(-604_800)
        default: nil
        }
    }

    private func chooseDownloadDirectory(for tab: Tab) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.downloadDirectory
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Settings.chooseDownloadDirectory(url)
                tab.webView.reload()
            } catch {
                self.showSettingsError(error)
            }
        }
    }

    private func makeDefaultBrowser(for tab: Tab) {
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https")
                tab.webView.reload()
            } catch {
                showSettingsError(error)
            }
        }
    }

    private func confirmSettingsChange(
        title: String, message: String, button: String, onCancel: (() -> Void)? = nil, action: @escaping () -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action() } else { onCancel?() }
        }
    }

    private func showSettingsError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}
