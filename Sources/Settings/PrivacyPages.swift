import Foundation

/// Builds the live privacy controls from the same policy model used by navigation and permissions.
enum PrivacyPages {
    @MainActor static var html: String {
        page(
            "privacy-network", title: "Network and security",
            content:
                toggle(
                    "HTTPS-first connections", detail: "Try HTTPS before using an unencrypted public website.", key: "HTTPSFirst",
                    defaultValue: true)
                + toggle(
                    "Fraudulent website warnings", detail: "Use WebKit's warnings for known deceptive websites.", key: "FraudWarnings",
                    defaultValue: true)
                + toggle(
                    "Block all cookies",
                    detail: "This can prevent sign-in and other website features. Existing cookies remain until you clear them.",
                    key: "BlockCookies", defaultValue: false)
                + select(
                    "Web security mode", key: "web-security", values: WebSecurityMode.available.map { ($0.rawValue, $0.name) },
                    selected: WebSecurityMode.defaultMode.rawValue)
                + "<p class=\"note\">Stricter modes reduce web capabilities and may affect website compatibility. System Lockdown Mode is never weakened. Modes apply on the next navigation.</p>"
                + (GlobalPrivacyControl.supported
                    ? toggle(
                        "Global Privacy Control",
                        detail:
                            "Send a preference that your data should not be sold or shared. WebKit applies the signal to pages, frames and resources. Changes apply on the next navigation.",
                        key: "GlobalPrivacyControl", defaultValue: true)
                    : "<p class=\"note\">WebKit's native Global Privacy Control support requires macOS 27 or newer.</p>")
                + "<div class=\"setting-row\" data-search-row><div class=\"setting-copy\"><span class=\"setting-title\">System encrypted DNS</span><p>\(BrowserPage.escape(SecureDNS.shared.status)) This configuration affects all apps. The selected provider receives domain queries.</p></div><a class=\"button\" href=\"aero://settings/action/secure-dns\">Configure…</a></div>"
                + "<div class=\"setting-row\" data-search-row><div class=\"setting-copy\"><span class=\"setting-title\">System proxies and network settings</span><p>Use macOS to configure network proxies and activate encrypted DNS.</p></div><a class=\"button\" href=\"aero://settings/action/network-settings\">Open…</a></div>"
                + "<p class=\"note\">Certificate validation stays enabled. System encrypted DNS requires macOS approval.</p>"
        )
            + page(
                "privacy-services", title: "Browser services",
                content:
                    toggle(
                        "Extension store artwork", detail: "Contact Apple's image servers when you open extension discovery.",
                        key: "ExtensionArtwork", defaultValue: true)
                    + toggle(
                        "Google search suggestions",
                        detail: "When Google is selected, send search words while typing. Addresses and private-tab text are not sent.",
                        key: "RemoteSuggestions", defaultValue: false)
                    + (Updates.shared.isConfigured
                        ? toggle(
                            "Check for updates automatically",
                            detail: "Check the signed update feed without sending browsing data or a system profile.",
                            key: "SUEnableAutomaticChecks", defaultValue: false)
                            + toggle(
                                "Download updates automatically", detail: "Let Sparkle download verified updates for installation.",
                                key: "SUAutomaticallyUpdate", defaultValue: false)
                        : "<p class=\"note\">Automatic updates require a configured publisher signing key and update feed.</p>")
                    + (ProtectionUpdates.shared.configured
                        ? toggle(
                            "Update protection lists automatically",
                            detail: "Check once a day. Only signed, validated lists are installed; failures keep the existing protection.",
                            key: "ProtectionListAutomaticUpdates", defaultValue: true) : "")
                    + "<div class=\"setting-row\" data-search-row><div class=\"setting-copy\"><span class=\"setting-title\">Telemetry</span><p>This browser has no telemetry service.</p></div></div>"
            )
    }

    static var browserSettings: String {
        page(
            "performance", title: "Performance",
            content:
                toggle(
                    "Put inactive tabs to sleep",
                    detail:
                        "Release inactive pages while protecting media and detected drafts. Tabs may sleep sooner under memory pressure.",
                    key: "SleepTabs", defaultValue: true)
                + select(
                    "Sleep after", key: "sleep-minutes", values: [5, 15, 30, 60, 120].map { (String($0), "\($0) minutes") },
                    selected: String(Settings.sleepMinutes))
                + "<div class=\"setting-row\" data-search-row><div class=\"setting-copy\"><span class=\"setting-title\">Keep these sites awake</span><p>Exceptions use the exact website origin. Private tabs stay in memory until closed.</p></div><a class=\"button\" href=\"aero://settings/action/sleep-exceptions\">Edit sites…</a></div>"
        )
            + page(
                "accessibility", title: "Accessibility",
                content:
                    select(
                        "Minimum website font size", key: "minimum-font",
                        values: [("0", "Website default")] + [9, 12, 14, 16, 18, 20].map { (String($0), "\($0) px") },
                        selected: String(Int(Settings.minimumFontSize)))
                    + toggle(
                        "Tab to highlight links", detail: "Use Tab to move through links as well as form controls on websites.",
                        key: "TabFocusesLinks", defaultValue: false)
                    + "<p class=\"note\">Interface motion follows macOS Reduce Motion. VoiceOver uses the native controls and WebKit's accessibility tree.</p>"
            )
            + page(
                "languages", title: "Languages",
                content:
                    select(
                        "Preferred website language", key: "language", values: languageChoices,
                        selected: UserDefaults.standard.string(forKey: "PreferredLanguage") ?? "system")
                    + "<p class=\"note\">Restart the browser after changing its language preference.</p>"
                    + "<div class=\"setting-row\" data-search-row><div class=\"setting-copy\"><span class=\"setting-title\">Spelling and writing</span><p>Use the Edit menu for spelling controls while typing. Manage system writing preferences in macOS.</p></div><a class=\"button\" href=\"aero://settings/action/keyboard-settings\">Keyboard settings…</a></div>"
            )
            + page(
                "reset", title: "Reset and troubleshooting",
                content:
                    "<div class=\"setting-row\" data-search-row><div class=\"setting-copy\"><span class=\"setting-title\">Reset browser preferences</span><p>Keep bookmarks, history, installed extensions and website decisions.</p></div><a class=\"button\" href=\"aero://settings/action/reset-preferences\">Reset…</a></div>"
                    + "<div class=\"setting-row\" data-search-row><div class=\"setting-copy\"><span class=\"setting-title\">Reset website permissions</span><p>Return website rules to their defaults. Cookies and stored website data are kept.</p></div><a class=\"button\" href=\"aero://settings/action/reset-site-policies\">Reset…</a></div>"
                    + "<div class=\"setting-row\" data-search-row><div class=\"setting-copy\"><span class=\"setting-title\">Disable all extensions</span><p>Keep them installed while checking whether an extension is causing a problem.</p></div><a class=\"button\" href=\"aero://settings/action/disable-extensions\">Disable…</a></div>"
            )
    }

    static let languageChoices = [
        ("system", "Use macOS preference"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh-Hans", "Chinese, simplified"),
    ]

    static func select(_ title: String, key: String, values: [(String, String)], selected: String) -> String {
        """
        <div class="setting-row" data-search-row><label for="\(key)">\(title)</label><select id="\(key)" data-setting="\(key)">
        \(values.map { "<option value=\"\(BrowserPage.escape($0.0))\"\($0.0 == selected ? " selected" : "")>\(BrowserPage.escape($0.1))</option>" }.joined())
        </select></div>
        """
    }

    static func policies(for site: URL? = nil) -> String {
        let origin = site.flatMap(BrowsingSecurity.origin)
        var result = "<div class=\"group\"><h2>\(origin.map(BrowserPage.escape) ?? "Default website behavior")</h2>"
        if origin != nil {
            result +=
                "<p class=\"note\">These saved rules apply to this exact origin.</p><a class=\"breadcrumb\" href=\"aero://settings#websites\">All website settings</a>"
        } else {
            result +=
                "<div class=\"page-actions\"><a class=\"button\" href=\"aero://settings/action/edit-site\">Configure a website…</a></div>"
        }
        for feature in SitePolicy.Feature.allCases {
            if feature == .location { if #available(macOS 27.0, *) {} else { continue } }
            let choices = SitePolicy.Decision.allCases.filter { $0 != .ask || feature.supportsAsk }
            let selected =
                origin.flatMap { SitePolicy.entries(feature)[$0] }
                ?? (origin == nil ? SitePolicy.defaultDecision(feature).rawValue : "default")
            let inheritance =
                origin == nil
                ? ""
                : "<option value=\"default\"\(selected == "default" ? " selected" : "")>Use default (\(SitePolicy.defaultDecision(feature).rawValue))</option>"
            result += """
                <div class="setting-row" data-search-row>
                  <label for="policy-\(feature.rawValue)">\(feature.name)</label>
                  <select id="policy-\(feature.rawValue)" data-site-policy="\(feature.rawValue)"\(origin.map { " data-origin=\"\(BrowserPage.escape($0))\"" } ?? "")>
                    \(inheritance)
                    \(choices.map { "<option value=\"\($0.rawValue)\"\($0.rawValue == selected ? " selected" : "")>\($0.rawValue.capitalized)</option>" }.joined())
                  </select>
                </div>
                """
            for (origin, decision) in (origin == nil ? SitePolicy.entries(feature) : [:]).sorted(by: { $0.key < $1.key }) {
                let action = BrowserPage.action(
                    "settings", "site-policy", parameters: ["feature": feature.rawValue, "origin": origin, "value": "default"])
                var destination = URLComponents(string: "aero://settings")!
                destination.queryItems = [URLQueryItem(name: "site", value: origin)]
                destination.fragment = "websites"
                result += """
                    <div class="setting-row" data-search-row>
                      <div class="setting-copy"><a href="\(BrowserPage.escape(destination.string!))">\(BrowserPage.escape(origin))</a><p>\(feature.name): \(BrowserPage.escape(decision.capitalized))</p></div>
                      <a class="button" href="\(action)">Use default</a>
                    </div>
                    """
            }
        }
        return result
            + "<p class=\"note\">Content changes apply when a page next loads. Device blocks stop existing access. Remote-image blocking does not remove images embedded directly in the page.</p></div>"
                + """
                <div class="group"><h2>Other website access</h2>
                  <div class="setting-row" data-search-row>
                    <div class="setting-copy"><span class="setting-title">Website notifications</span>
                      <p>Website notifications are not supported by this browser.</p></div>
                  </div>
                  <div class="setting-row" data-search-row>
                    <div class="setting-copy"><span class="setting-title">Clipboard access</span>
                      <p>WebKit controls website clipboard access. Copying requires a website interaction; reading may require choosing Paste. Persistent per-site clipboard permissions are not available.</p></div>
                  </div>
                </div>
                """
            + "<div class=\"group\"><h2>Autoplay</h2>"
            + select(
                "Automatic media playback", key: "autoplay",
                values: [("allow", "Allow autoplay"), ("sound", "Require a click for sound"), ("block", "Require a click for all media")],
                selected: UserDefaults.standard.string(forKey: "Autoplay") ?? "sound")
            + "<p class=\"note\">The autoplay preference applies to newly opened tabs. Audio and video playback rules can stop media in a current tab.</p></div>"
    }

    private static func page(_ id: String, title: String, content: String) -> String {
        """
        <section class="panel" id="\(id)" data-panel-content hidden>
          <header class="page-heading"><a class="breadcrumb" href="\(id.hasPrefix("privacy-") ? "#privacy" : "#general")" data-panel-link>\(id.hasPrefix("privacy-") ? "Privacy and security" : "Settings")</a><h1>\(title)</h1></header>
          <div class="group">\(content)</div>
        </section>
        """
    }

    private static func toggle(_ title: String, detail: String, key: String, defaultValue: Bool) -> String {
        let enabled = UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
        return """
            <div class="setting-row" data-search-row>
              <div class="setting-copy"><label for="\(key)">\(title)</label><p>\(detail)</p></div>
              <input id="\(key)" type="checkbox" switch data-privacy-setting="\(key)"\(enabled ? " checked" : "")>
            </div>
            """
    }
}
