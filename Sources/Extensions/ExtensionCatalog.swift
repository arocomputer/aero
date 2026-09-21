import AppKit
import WebKit

/// Metadata for an extension distributed by its developer through the Mac App Store.
private struct CatalogExtension {
    let name: String
    let summary: String
    let category: String
    let appID: Int
    let bundleIdentifier: String
    let iconURL: String
}

/// Installed-first extension management, with explicit local and App Store discovery sections.
@MainActor enum ExtensionCatalog {
    static let pageURL = URL(string: "aero://extensions")!

    // WebKit has no extension registry. These entries come from Apple's extension collection and
    // retain the developer's bundle identifier and App Store artwork.
    private static let available: [CatalogExtension] = [
        entry(
            "1Password", "Fill and save passwords with 1Password.", "privacy productivity", 1_569_813_296,
            "com.1password.safari", "Purple221/v4/c8/4e/84/c84e84d0-e821-ecb1-ee3e-c50c7d55208c/AppIcon-0-0-85-220-0-5-0-2x.png"),
        entry(
            "Noir", "Give every website a carefully generated dark mode.", "appearance", 1_592_917_505,
            "nl.jeffreykuiken.NoirApp.mac",
            "Purple211/v4/23/36/1c/23361c0b-8805-fab6-ef39-4ad2ce17f5fa/AppIcon-0-0-1x_U007euniversal-0-0-0-1-0-85-220.png"),
        entry(
            "uBlock Origin Lite", "Block ads and trackers with declarative rules.", "privacy", 6_745_342_698,
            "net.raymondhill.uBlock-Origin-Lite",
            "Purple211/v4/c7/5c/3b/c75c3b55-7864-8074-1999-130d9a5f3b38/AppIcon-0-0-1x_U007epad-0-1-sRGB-85-220.png"),
        entry(
            "Tabs Saver", "Save, restore, and organize groups of tabs.", "productivity", 1_440_006_971,
            "com.alexandrudenk.tabs-saver-for-safari",
            "Purple221/v4/83/02/95/8302953b-cb9d-ac3f-0db7-dce87120644a/TabsSaver_Icon-0-0-1x_U007epad-0-1-0-sRGB-85-220.png"),
        entry(
            "StopTheMadness Pro", "Restore standard browser controls that websites disable.", "productivity", 6_471_380_298,
            "com.underpassapp.StopTheMadnessPro",
            "Purple221/v4/d0/9b/23/d09b2322-0ba9-f20f-ed50-e7ee28e0c68a/AppIcon-0-0-1x_U007epad-0-1-P3-85-220.png"),
        entry(
            "xSearch", "Search websites and custom engines from one shortcut.", "productivity", 1_579_902_068,
            "com.iAugus.xSearch", "Purple221/v4/a4/35/15/a43515f3-933c-f535-d49d-9b9c71558099/xSearch-0-0-1x_U007epad-0-1-sRGB-85-220.png"),
        entry(
            "Tab Space", "Save sessions and move quickly between open tabs.", "productivity", 1_473_726_602,
            "cn.joyuer.Tab-Works", "Purple211/v4/86/a4/e8/86a4e819-597f-df5a-2d2a-f36f2ef600ba/Tab_Space-0-0-85-220-0-6-0-2x.png"),
        entry(
            "Dark Reader", "Apply an adjustable dark theme to websites.", "appearance", 1_438_243_180,
            "org.darkreader.DarkReaderSafari",
            "Purple211/v4/e8/91/11/e8911158-a4b1-3a6f-c8b9-1193164ee5ef/AppIcon-0-0-1x_U007emarketing-0-8-0-85-220.png"),
        entry(
            "TabPilot", "Search and switch tabs without leaving the keyboard.", "productivity", 6_760_547_850,
            "com.ondrejbarta.tabpilot", "Purple221/v4/29/31/01/2931017c-2d27-3a91-f439-72b095656671/Icon-0-0-85-220-0-6-0-2x.png"),
        entry(
            "Momentum", "Replace the new-tab page with focus tools and inspiration.", "productivity appearance", 1_564_329_434,
            "com.momentumdash.momentum",
            "Purple221/v4/c6/59/d5/c659d54a-02fd-986f-b8cc-9d40b7f1a074/AppIcon-0-0-1x_U007emarketing-0-8-0-85-220.png"),
        entry(
            "Mate", "Translate words and pages without leaving the browser.", "productivity", 1_005_088_137,
            "andriiliakh.Instant-Translate", "Purple221/v4/b9/2f/06/b92f069a-1dba-e6de-2d19-08f15c8beff3/AppIcon-0-0-85-220-0-0-5-0-2x.png"),
        entry(
            "Instapaper", "Save articles to read later in a focused layout.", "productivity", 288_545_208,
            "com.marcoarment.instapaperpro",
            "Purple211/v4/5e/f9/0b/5ef90b91-f5db-c381-e5f7-f80012f4d17a/AppIcon-0-0-1x_U007epad-0-8-0-85-220.png"),
        entry(
            "Raindrop.io", "Save and organize bookmarks in Raindrop.io.", "productivity", 1_549_370_672,
            "io.raindrop.safari", "Purple211/v4/8e/e7/9f/8ee79fa0-c578-c184-18ee-0f5c86e30fed/AppIcon-0-0-85-220-0-6-0-2x.png"),
        entry(
            "Wayback Machine", "Open archived versions of pages and save new snapshots.", "developer productivity", 1_472_432_422,
            "archive.org.waybackmachine.mac",
            "Purple126/v4/80/aa/8b/80aa8b04-41e1-a86b-9808-c2c83666e874/AppIcon-0-0-85-220-0-0-0-0-4-0-0-0-2x-sRGB-0-0-0-0-0.png"),
        entry(
            "NewsGuard", "See source credibility and transparency ratings while browsing.", "privacy productivity", 1_485_417_785,
            "com.newsguardtech.app-ios",
            "Purple211/v4/02/3a/41/023a4124-62e7-4b98-d852-c4d0af036315/AppIcon-0-0-1x_U007emarketing-0-8-0-85-220.png"),
        entry(
            "Auto Scroll and Read", "Scroll long pages automatically at an adjustable speed.", "productivity", 6_657_988_236,
            "AG.Auto-Scroll-and-Read", "Purple221/v4/47/9e/7c/479e7c8e-b43e-8775-0326-a9d59f7d32f8/AppIcon-0-0-1x_U007epad-0-1-85-220.png"),
        entry(
            "GoodLinks", "Save links and read them later in a clean reader.", "productivity", 1_474_335_294,
            "com.ngocluu.goodlinks", "Purple211/v4/9c/8c/80/9c8c80fc-795f-8333-d574-0651dfc56fcf/AppIcon-0-0-1x_U007epad-0-1-85-220.png"),
        entry(
            "RSS Button", "Discover feeds and send them to an RSS reader.", "productivity", 1_437_501_942,
            "com.bitpiston.RSSButton4Safari",
            "Purple126/v4/72/fe/70/72fe70b3-116c-5ed7-4471-5137aaeaec35/AppIcon-0-0-85-220-0-0-0-0-4-0-0-0-2x-sRGB-0-0-0-0-0.png"),
    ]

    /// Catalog images remain dormant until discovery is opened. No remote metadata fetch is needed.
    static func html() -> String { html(manager: .shared) }

    static func html(manager: WebExtensions) -> String {
        let availableCards = available.map { card(for: $0, manager: manager) }.joined(separator: "\n")
        let onMacCards = manager.nativeExtensionApps()
            .map { nativeCard(for: $0, manager: manager) }.joined(separator: "\n")
        let installedCards = manager.contexts.map { installedCard(for: $0, manager: manager) }.joined(separator: "\n")
        let failed = manager.failedInstallations.map { item in
            """
            <article class="extension" data-search-row>
              <div class="extension-header">
                <div class="extension-copy">
                  <h3>\(escape(item.name))</h3>
                  <p class="description">Could not load this extension. \(escape(item.message))</p>
                </div>
                <a class="button danger" href="\(BrowserPage.action("extensions", "remove-failed", parameters: ["id": item.id]))">Remove…</a>
              </div>
            </article>
            """
        }.joined(separator: "\n")
        return BrowserPage.render(
            "Extensions",
            values: [
                "appName": escape(appName),
                "runtimeStatus": manager.safeMode
                    ? "<p class=\"note\">Extensions are temporarily disabled for this launch. Saved enable switches apply again after a normal restart.</p>"
                    : "",
                "available": availableCards,
                "onMac": onMacCards.isEmpty ? "<p class=\"empty\">No compatible extension apps were found on this Mac.</p>" : onMacCards,
                "installed": (installedCards + failed).isEmpty
                    ? "<p class=\"empty\">No extensions installed. Install a local WebExtension or choose Find extensions.</p>"
                    : installedCards + failed,
            ])
    }

    static func storeURL(appID: Int) -> URL? {
        guard appID > 0 else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appID)")
    }

    static func canInstall(bundleIdentifier: String) -> Bool {
        available.contains { $0.bundleIdentifier == bundleIdentifier }
            || WebExtensions.shared.nativeExtensionApps().contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private static func entry(
        _ name: String, _ summary: String, _ category: String, _ appID: Int, _ bundleIdentifier: String, _ artwork: String
    ) -> CatalogExtension {
        CatalogExtension(
            name: name, summary: summary, category: category, appID: appID,
            bundleIdentifier: bundleIdentifier,
            iconURL: "https://is1-ssl.mzstatic.com/image/thumb/\(artwork)/200x200bb.png")
    }

    private static func card(for item: CatalogExtension, manager: WebExtensions) -> String {
        let action: String
        if manager.isInstalled(appBundleIdentifier: item.bundleIdentifier) {
            action = #"<span class="status">Installed</span>"#
        } else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier) != nil {
            action =
                #"<a class="button" href="\#(BrowserPage.action("extensions", "install-native", parameters: ["bundle": item.bundleIdentifier]))">Add to browser</a>"#
        } else {
            action = #"<a class="button" href="aero://extensions/action/open-store?id=\#(item.appID)">View in App Store</a>"#
        }
        return cardHTML(
            name: item.name, summary: item.summary, category: item.category,
            icon: (UserDefaults.standard.object(forKey: "ExtensionArtwork") as? Bool ?? true) ? item.iconURL : manager.fallbackIconDataURL,
            action: action)
    }

    private static func nativeCard(for app: NativeExtensionApp, manager: WebExtensions) -> String {
        let action =
            manager.isInstalled(appBundleIdentifier: app.bundleIdentifier)
            ? #"<span class="status">Installed</span>"#
            : #"<a class="button" href="\#(BrowserPage.action("extensions", "install-native", parameters: ["bundle": app.bundleIdentifier]))">Add to browser</a>"#
        return cardHTML(
            name: app.name, summary: "Compatible WebExtension found on this Mac.",
            category: "on-mac productivity", icon: app.iconDataURL, action: action)
    }

    private static func installedCard(for context: WKWebExtensionContext, manager: WebExtensions) -> String {
        let name = context.webExtension.displayName ?? "Extension"
        let summary = context.webExtension.displayDescription ?? "Loaded by \(appName)'s WebKit extension runtime."
        let identifier = escape(context.uniqueIdentifier)
        let enabled = manager.isEnabled(context)
        let newTab =
            context.overrideNewTabPageURL == nil
            ? ""
            : """
            <a class="button" href="\(BrowserPage.action("extensions", "new-tab", parameters: ["id": context.uniqueIdentifier]))">\(manager.usesNewTabOverride(context) ? "Restore default new tab" : "Use for new tabs")</a>
            """
        let options =
            context.optionsPageURL == nil || !enabled || manager.safeMode
            ? "" : #"<a class="button" href="aero://extensions/action/options?id=\#(identifier)">Extension options</a>"#
        let requested =
            context.webExtension.requestedPermissions.map { permissionName($0.rawValue) }.sorted()
            + context.webExtension.requestedPermissionMatchPatterns.map(\.string).sorted()
        let requestedList = requested.isEmpty ? "None declared" : requested.map(escape).joined(separator: "<br>")
        let permissionRows = context.grantedPermissions.keys.sorted { $0.rawValue < $1.rawValue }.map { permission in
            permissionRow(
                permissionName(permission.rawValue), action: "revoke-permission",
                parameters: ["id": context.uniqueIdentifier, "permission": permission.rawValue])
        }
        let siteRows = context.grantedPermissionMatchPatterns.keys.sorted { $0.string < $1.string }.map { pattern in
            permissionRow(pattern.string, action: "revoke-site", parameters: ["id": context.uniqueIdentifier, "pattern": pattern.string])
        }
        let granted = (permissionRows + siteRows).joined(separator: "\n")
        let denied =
            context.deniedPermissions.keys.map { permissionName($0.rawValue) } + context.deniedPermissionMatchPatterns.keys.map(\.string)
        let deniedHTML =
            denied.isEmpty
            ? ""
            : """
            <h2>Denied access</h2><p class="description">\(denied.sorted().map(escape).joined(separator: "<br>"))</p>
            <div class="page-actions"><a class="button" href="\(BrowserPage.action("extensions", "reset-denials", parameters: ["id": context.uniqueIdentifier]))">Allow asking again</a></div>
            """
        let errors = (context.webExtension.errors + context.errors).map { escape($0.localizedDescription) }.joined(separator: "<br>")
        return """
            <article class="extension" data-search-row>
              <div class="extension-header">
                <img class="extension-icon" src="\(escape(manager.iconDataURL(for: context)))" alt="">
                <div class="extension-copy">
                  <h3>\(escape(name))</h3>
                  <p class="description">\(escape(summary))</p>
                </div>
                <input type="checkbox" switch data-extension-toggle="\(identifier)" aria-label="Enable \(escape(name))"\(enabled ? " checked" : "")>
              </div>
              <details class="extension-details" data-detail="\(identifier)">
                <summary>Details and permissions</summary>
                <dl class="metadata">
                  <dt>Version</dt><dd>\(escape(context.webExtension.displayVersion ?? "Not provided"))</dd>
                  <dt>Source</dt><dd>\(escape(manager.installationSource(for: context)))</dd>
                  <dt>Requested access</dt><dd>\(requestedList)</dd>
                </dl>
                <h2>Granted access</h2>
                <ul class="permission-list">\(granted.isEmpty ? "<li>No explicit permissions granted.</li>" : granted)</ul>
                <p class="note">Revoked access may be requested again. Reload open pages to clear changes an extension has already made.</p>
                \(deniedHTML)
                \(errors.isEmpty ? "" : "<h2>Extension errors</h2><p class=\"description\">\(errors)</p>")
                <div class="page-actions">
                  \(options)
                  \(newTab)
                  <a class="button danger" href="aero://extensions/action/remove?id=\(identifier)">Remove…</a>
                </div>
              </details>
            </article>
            """
    }

    private static func permissionRow(_ name: String, action: String, parameters: [String: String]) -> String {
        """
        <li>
          <span>\(escape(name))</span>
          <a class="button" href="\(BrowserPage.action("extensions", action, parameters: parameters))" aria-label="Revoke \(escape(name))">Revoke</a>
        </li>
        """
    }

    /// Uses plain descriptions for common capabilities, retaining API names for unfamiliar permissions.
    private static func permissionName(_ permission: String) -> String {
        switch permission {
        case "storage": "Store extension data"
        case "tabs": "Read tab information"
        case "activeTab": "Access the current tab when you use the extension"
        case "scripting": "Run scripts on permitted websites"
        case "cookies": "Read and change cookies on permitted websites"
        case "webRequest": "Observe requests on permitted websites"
        case "downloads": "Manage downloads"
        case "history": "Read browsing history"
        case "nativeMessaging": "Communicate with a companion app"
        case "clipboardRead": "Read clipboard contents"
        case "clipboardWrite": "Write to the clipboard"
        case "notifications": "Show notifications"
        case "declarativeNetRequest": "Block or redirect network requests"
        default: permission
        }
    }

    /// Escapes extension-supplied text and addresses; only the caller-built action is markup.
    static func cardHTML(
        name: String, summary: String, category: String, icon: String, action: String
    ) -> String {
        let source = icon.hasPrefix("https:") ? "data-src" : "src"
        return """
            <article class="extension" data-search-row data-keywords="\(escape(category))">
              <div class="extension-header">
                <img class="extension-icon" \(source)="\(escape(icon))" alt="">
                <div class="extension-copy">
                  <h3>\(escape(name))</h3>
                  <p class="description">\(escape(summary))</p>
                  <p class="note">Compatibility with this browser has not been verified.</p>
                </div>
                \(action)
              </div>
            </article>
            """
    }

    private static func escape(_ text: String) -> String {
        BrowserPage.escape(text)
    }
}

/// Serves trusted Aero pages from memory instead of granting a remote site browser privileges.
final class AeroPages: NSObject, WKURLSchemeHandler {
    static let shared = AeroPages()
    private var pending: Set<ObjectIdentifier> = []

    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(self, forURLScheme: "aero")
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.path.isEmpty || url.path == "/" else {
            return urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
        }
        if url.host == "site-data" {
            let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
            pending.insert(identifier)
            webView.configuration.websiteDataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) {
                [weak self] records in
                guard self?.pending.remove(identifier) != nil else { return }
                let data = Data(LibraryPage.siteData(records, url: url).utf8)
                urlSchemeTask.didReceive(
                    URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
            return
        }
        let html: String
        switch url.host {
        case "extensions": html = ExtensionCatalog.html()
        case "settings":
            let site = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "site" }?.value.flatMap(
                URL.init(string:))
            html = SettingsPage.html(site: site)
        case "history", "bookmarks", "downloads":
            html = LibraryPage.html(for: url, downloads: (webView.navigationDelegate as? Tab)?.owner?.downloads)
        default:
            return urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
        }
        let data = Data(html.utf8)
        let response = URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        pending.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }
}
