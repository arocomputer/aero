import WebKit

/// Uses WebKit's native GPC policy, which covers the document, frames and subresource requests.
/// The public property arrived in macOS 27. KVC keeps builds using older SDKs source-compatible;
/// no private selectors or JavaScript substitutes are used on earlier systems.
@MainActor enum GlobalPrivacyControl {
    static var supported: Bool {
        guard #available(macOS 27.0, *) else { return false }
        return WKWebpagePreferences.instancesRespond(to: NSSelectorFromString("setGlobalPrivacyControlEnabled:"))
    }

    static func apply(to preferences: WKWebpagePreferences, enabled: Bool? = nil) {
        guard supported else { return }
        preferences.setValue(enabled ?? Settings.globalPrivacyControl, forKey: "globalPrivacyControlEnabled")
    }
}
