import Foundation
import WebKit

/// Public WebKit exploit hardening, not fingerprinting protection. Enhanced disables JavaScript JIT
/// and increases memory tagging coverage; Lockdown also restricts web features.
enum WebSecurityMode: String, CaseIterable {
    case standard, enhanced, lockdown
    var name: String { rawValue.capitalized }
    static var available: [Self] {
        if #available(macOS 26.4, *) { return allCases }
        return [.standard, .lockdown]
    }
    static var defaultMode: Self {
        let value = Self(rawValue: UserDefaults.standard.string(forKey: "WebSecurityMode") ?? "") ?? .standard
        return available.contains(value) ? value : .standard
    }
    static func mode(for url: URL) -> Self {
        guard let origin = BrowsingSecurity.origin(url),
            let value = (UserDefaults.standard.dictionary(forKey: "SiteSecurityModes") as? [String: String])?[origin],
            let mode = Self(rawValue: value), available.contains(mode)
        else { return defaultMode }
        return mode
    }
    static func set(_ mode: Self?, for origin: String) {
        var values = UserDefaults.standard.dictionary(forKey: "SiteSecurityModes") as? [String: String] ?? [:]
        values[origin] = mode?.rawValue
        UserDefaults.standard.set(values, forKey: "SiteSecurityModes")
    }

    /// Applies main-frame restrictions inherited by subframes and opened windows, preserving system
    /// Lockdown. KVC for the public macOS 26.4 property keeps older SDK builds source-compatible.
    @MainActor func apply(to preferences: WKWebpagePreferences) {
        let systemLockdown = WKWebpagePreferences().isLockdownModeEnabled
        if #available(macOS 26.4, *) {
            // WKSecurityRestrictionMode raw values: none = 0, maximizeCompatibility = 1, lockdown = 2.
            let value = systemLockdown || self == .lockdown ? 2 : self == .enhanced ? 1 : 0
            preferences.setValue(value, forKey: "securityRestrictionMode")
        } else {
            preferences.isLockdownModeEnabled = systemLockdown || self == .lockdown
        }
    }
}
