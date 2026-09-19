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

/// Aero's first-party extension catalog and its stable internal URL.
enum ExtensionCatalog {
    static let pageURL = URL(string: "aero://extensions")!

    private static let mark = """
        <svg viewBox="0 0 534 440" aria-hidden="true"><path d="M.777 431.059C59.871 262.605 161.331 0 266.516 0S473.161 262.605 532.255 431.059c1.724 4.915.484 10.746-2.773 6.682C446.411 334.091 362.051 227 266.516 227S86.621 334.091 3.55 437.741C.293 441.805-.947 435.974.777 431.059Z" fill="currentColor"/></svg>
        """

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

    /// Renders Extensions.html with current install state. Remote pages never receive management actions.
    static func html() -> String {
        let manager = WebExtensions.shared
        let knownBundles = Set(available.map(\.bundleIdentifier))
        let availableCards = available.map { card(for: $0, manager: manager) }.joined(separator: "\n")
        let onMacCards = manager.nativeExtensionApps().filter { !knownBundles.contains($0.bundleIdentifier) }
            .map { nativeCard(for: $0, manager: manager) }.joined(separator: "\n")
        let installedCards = manager.contexts.map { installedCard(for: $0, manager: manager) }.joined(separator: "\n")

        let templateURL = Bundle.module.url(forResource: "Extensions", withExtension: "html")!
        let template = (try? String(contentsOf: templateURL, encoding: .utf8)) ?? "Extensions.html is unavailable."
        return
            template
            .replacingOccurrences(of: "{{mark}}", with: mark)
            .replacingOccurrences(of: "{{appName}}", with: escape(appName))
            .replacingOccurrences(of: "{{available}}", with: availableCards)
            .replacingOccurrences(
                of: "{{onMac}}",
                with: onMacCards.isEmpty
                    ? empty("No additional compatible extension apps were found on this Mac.", category: "on-mac") : onMacCards
            )
            .replacingOccurrences(
                of: "{{installed}}",
                with: installedCards.isEmpty
                    ? empty("Extensions you add to \(appName) will appear here.", category: "installed") : installedCards
            )
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
            action = #"<span class="installed">Installed</span>"#
        } else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleIdentifier) != nil {
            action =
                #"<a class="button" href="aero://extensions/action/install-native?bundle=\#(item.bundleIdentifier)">Add to \#(escape(appName))</a>"#
        } else {
            action = #"<a class="button" href="aero://extensions/action/open-store?id=\#(item.appID)">Get</a>"#
        }
        return cardHTML(
            name: item.name, summary: item.summary, category: item.category, icon: item.iconURL, action: action,
            appID: item.appID)
    }

    private static func nativeCard(for app: NativeExtensionApp, manager: WebExtensions) -> String {
        let action =
            manager.isInstalled(appBundleIdentifier: app.bundleIdentifier)
            ? #"<span class="installed">Installed</span>"#
            : #"<a class="button" href="aero://extensions/action/install-native?bundle=\#(app.bundleIdentifier)">Add to \#(escape(appName))</a>"#
        return cardHTML(
            name: app.name, summary: "Compatible WebExtension found on this Mac.",
            category: "on-mac productivity", icon: app.iconDataURL, action: action)
    }

    private static func installedCard(for context: WKWebExtensionContext, manager: WebExtensions) -> String {
        let name = context.webExtension.displayName ?? "Extension"
        let summary = context.webExtension.displayDescription ?? "Loaded by \(appName)'s WebKit extension runtime."
        let identifier = escape(context.uniqueIdentifier)
        let options =
            context.optionsPageURL == nil
            ? "" : #"<a class="button secondary" href="aero://extensions/action/options?id=\#(identifier)">Options</a>"#
        let action = #"\#(options)<a class="button danger" href="aero://extensions/action/remove?id=\#(identifier)">Remove</a>"#
        return cardHTML(name: name, summary: summary, category: "installed", icon: manager.iconDataURL(for: context), action: action)
    }

    private static func cardHTML(
        name: String, summary: String, category: String, icon: String, action: String, appID: Int? = nil
    ) -> String {
        let appAttribute = appID.map { #" data-app-id="\#($0)""# } ?? ""
        return """
            <article class="card extension"\(appAttribute) data-search="\(escape((name + " " + summary).lowercased()))" data-category="\(escape(category))">
              <div class="card-inner"><div class="card-top"><img class="icon" src="\(escape(icon))" alt=""><div class="card-title"><h3>\(escape(name))</h3><span class="category">\(categoryLabel(category))</span></div></div><p>\(escape(summary))</p><div class="actions">\(action)</div></div>
            </article>
            """
    }

    private static func empty(_ message: String, category: String) -> String {
        #"<div class="empty extension" data-search="" data-category="\#(category)">\#(escape(message))</div>"#
    }

    private static func categoryLabel(_ categories: String) -> String {
        switch categories.split(separator: " ").first {
        case "privacy": "Privacy & Security"
        case "appearance": "Appearance"
        case "developer": "Developer Tools"
        case "installed": "Installed"
        case "on-mac": "On This Mac"
        default: "Productivity"
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Serves trusted Aero pages from memory instead of granting a remote site browser privileges.
final class AeroPages: NSObject, WKURLSchemeHandler {
    static let shared = AeroPages()

    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(self, forURLScheme: "aero")
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.path.isEmpty || url.path == "/" else {
            return urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
        }
        let html: String
        switch url.host {
        case "extensions": html = ExtensionCatalog.html()
        case "settings": html = SettingsPage.html()
        default:
            return urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable))
        }
        let data = Data(html.utf8)
        let response = URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
