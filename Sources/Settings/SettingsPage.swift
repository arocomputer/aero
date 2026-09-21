import AppKit
import Foundation

/// Supplies escaped preference values and saved exceptions to the bundled settings template.
enum SettingsPage {
    static let pageURL = URL(string: "aero://settings")!

    @MainActor static func html(site: URL? = nil) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let exceptions = TrackerProtection.shared.exceptions.sorted()
        let exceptionRows = exceptions.map { host in
            let action = BrowserPage.action("settings", "remove-tracker-exception", parameters: ["value": host])
            return """
                <div class="setting-row">
                  <span>\(BrowserPage.escape(host))</span>
                  <a class="button" href="\(action)" aria-label="Restore protection for \(BrowserPage.escape(host))">Remove exception</a>
                </div>
                """
        }.joined(separator: "\n")
        var values: [String: String] = [
            "appName": BrowserPage.escape(appName),
            "trashIcon": BrowserPage.symbol("trash"),
            "shieldIcon": BrowserPage.symbol("shield"),
            "lockIcon": BrowserPage.symbol("lock"),
            "sitesIcon": BrowserPage.symbol("slider.horizontal.3"),
            "servicesIcon": BrowserPage.symbol("network"),
            "siteZoomRows": Settings.siteZooms.sorted { $0.key < $1.key }.map { origin, zoom in
                "<div class=\"setting-row\" data-search-row><div class=\"setting-copy\"><span class=\"setting-title\">\(BrowserPage.escape(origin))</span><p>\(Int((zoom * 100).rounded()))%</p></div><a class=\"button\" href=\"\(BrowserPage.action("settings", "reset-site-zoom", parameters: ["value": origin]))\">Use default</a></div>"
            }.joined(separator: "\n"),
            "version": BrowserPage.escape(build.map { "Version \(version) (\($0))" } ?? "Version \(version)"),
            "updateStatus": BrowserPage.escape(Updates.shared.status),
            "updateAction": Updates.shared.canCheck
                ? "<a class=\"button\" href=\"aero://settings/action/check-updates\">Check for updates…</a>" : "",
            "trackersChecked": Settings.trackerBlocking ? " checked" : "",
            "protectionListStatus": BrowserPage.escape(
                (try? ProtectionList.current()).map { "List \($0.version) · \($0.domains.count) tracker domains" }
                    ?? "Protection list unavailable"),
            "protectionUpdateAction": ProtectionUpdates.shared.configured
                ? "<a class=\"button\" href=\"aero://settings/action/update-protection\">Update protection list</a>" : "",
            "protectionUpdateStatus": BrowserPage.escape(ProtectionUpdates.shared.message ?? ""),
            "downloadFolder": BrowserPage.escape(Settings.downloadDirectory.path),
            "appearances": choices(Appearance.allCases.map { ($0.rawValue, $0.name) }, selected: Settings.appearance.rawValue),
            "searchEngines": choices(
                SearchEngine.allCases.map { ($0.rawValue, $0.name) } + CustomSearch.engines.map { ("custom:" + $0.id.uuidString, $0.name) },
                selected: CustomSearch.selected.map { "custom:" + $0.id.uuidString } ?? Settings.searchEngine.rawValue),
            "customEngines": customEngineRows(),
            "zoomChoices": choices(Settings.zoomLevels.map { (String($0), "\($0)%") }, selected: String(Settings.defaultZoom)),
            "historyChoices": choices(
                [("0", "Until I clear it"), ("90", "90 days"), ("30", "30 days"), ("-1", "Don't save history")],
                selected: String(Settings.historyDays)),
            "faviconsChecked": Settings.showsFavicons ? " checked" : "",
            "askDownloadsChecked": Settings.asksDownloadDestination ? " checked" : "",
            "exceptionCount": String(exceptions.count),
            "trackerExceptions": exceptions.isEmpty
                ? "<p class=\"empty\">No tracker exceptions. Protection is on for every site.</p>" : exceptionRows,
            "sitePolicies": PrivacyPages.policies(for: site),
            "privacyPages": PrivacyPages.html,
            "browserPages": PrivacyPages.browserSettings,
            "startupChoices": choices(
                [("blank", "Open a new tab"), ("pages", "Open specific pages"), ("restore", "Continue the previous session")],
                selected: Settings.startupMode),
            "suggestionsChecked": UserDefaults.standard.bool(forKey: "RemoteSuggestions") ? " checked" : "",
            "newTabStatus": WebExtensions.shared.newTabContext.map {
                "New tabs use \(BrowserPage.escape($0.webExtension.displayName ?? "your selected extension"))."
            } ?? "New tabs open the address field.",
            "passkeyStatus": BrowserPage.escape(Passkeys.status),
            "passkeyAction": Passkeys.canRequestAccess
                ? "<a class=\"button\" href=\"aero://settings/action/allow-passkeys\">Allow…</a>" : "",
            "defaultStatus": Settings.isDefaultBrowser ? "This is your default browser." : "Another app currently opens web links.",
            "defaultAction": Settings.isDefaultBrowser
                ? "<span class=\"status\">Default</span>"
                : "<a class=\"button\" href=\"aero://settings/action/make-default\">Make default</a>",
        ]
        if #available(macOS 27.0, *) {
            values["locationNote"] = "Location requests also require approval. Use Site Information to block an origin."
        } else {
            values["locationNote"] = "Location access is managed by macOS on this system."
        }
        return BrowserPage.render("Settings", values: values)
    }

    private static func choices(_ items: [(String, String)], selected: String) -> String {
        items.map { value, title in
            "<option value=\"\(BrowserPage.escape(value))\"\(value == selected ? " selected" : "")>\(BrowserPage.escape(title))</option>"
        }.joined(separator: "\n")
    }

    private static func customEngineRows() -> String {
        CustomSearch.engines.map { engine -> String in
            let action = BrowserPage.action("settings", "edit-search", parameters: ["value": engine.id.uuidString])
            return """
                <div class="setting-row" data-search-row>
                  <div class="setting-copy">
                    <span class="setting-title">\(BrowserPage.escape(engine.name))</span>
                    <p>\(BrowserPage.escape(engine.shortcut)) · \(BrowserPage.escape(engine.template))</p>
                  </div>
                  <a class="button" href="\(action)">Edit…</a>
                </div>
                """
        }.joined(separator: "\n")
    }

}
