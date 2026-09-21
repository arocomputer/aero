import Foundation
import WebKit
import Darwin

/// Rules at the boundary between untrusted pages and browser-owned capabilities.
enum BrowsingSecurity {
    /// Canonical web origin, including the effective port, for native permission and request checks.
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else {
            return nil
        }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    /// Only a top-level local page may invoke actions for its own settings or extensions origin.
    static func allowsInternalAction(_ target: URL, source: URL?, isMainFrame: Bool, targetsMainFrame: Bool) -> Bool {
        guard isMainFrame, targetsMainFrame, let source,
            source.scheme == "aero", target.scheme == "aero",
            ["settings", "extensions", "history", "bookmarks", "downloads", "site-data"].contains(source.host ?? ""),
            source.host == target.host,
            source.path.isEmpty || source.path == "/", source.user == nil, source.password == nil,
            source.port == nil, target.port == nil, target.user == nil, target.password == nil
        else { return false }
        return target.path.hasPrefix("/action/")
    }

    /// Keeps custom schemes usable, including extension backgrounds. Tab selects HTTPS-first for
    /// public web navigation; engine certificate checks and fraudulent-site warnings remain enabled.
    @MainActor static func configure(_ configuration: WKWebViewConfiguration) {
        GlobalPrivacyControl.apply(to: configuration.defaultWebpagePreferences)
        configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = UserDefaults.standard.object(forKey: "FraudWarnings") as? Bool ?? true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.tabFocusesLinks = UserDefaults.standard.bool(forKey: "TabFocusesLinks")
        switch UserDefaults.standard.string(forKey: "Autoplay") ?? "sound" {
        case "allow": configuration.mediaTypesRequiringUserActionForPlayback = []
        case "block": configuration.mediaTypesRequiringUserActionForPlayback = .all
        default: configuration.mediaTypesRequiringUserActionForPlayback = .audio
        }
    }

    /// HTTPS-first applies to web addresses, never to browser-owned or extension URL schemes.
    static func httpsPolicy(for url: URL?) -> WKWebpagePreferences.UpgradeToHTTPSPolicy {
        !AddressInput.isWeb(url) || isLocalDestination(url) || (UserDefaults.standard.object(forKey: "HTTPSFirst") as? Bool == false)
            ? .keepAsRequested : .userMediatedFallbackToHTTP
    }

    /// Local development and LAN devices may deliberately use HTTP. Public destinations always
    /// retain HTTPS-first. Classify literal addresses without a DNS lookup or a suffix guess.
    static func isLocalDestination(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 {
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            return bytes[0] == 127 || bytes[0] == 10
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        }
        var address6 = in6_addr()
        if inet_pton(AF_INET6, host, &address6) == 1 {
            let bytes = withUnsafeBytes(of: address6) { Array($0) }
            return (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
                || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        return false
    }

    /// Presents an origin, never a page-supplied title or URL credentials, in native prompts.
    static func label(scheme: String, host: String, port: Int) -> String {
        guard ["https", "http"].contains(scheme), !host.isEmpty else { return "An embedded page" }
        let suffix = port == 0 || (scheme == "https" && port == 443) || (scheme == "http" && port == 80) ? "" : ":\(port)"
        let host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(host)\(suffix)"
    }
}
