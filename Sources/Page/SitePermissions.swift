import Foundation

/// Device permission kinds and legacy denial helpers. Effective decisions are stored by SitePolicy.
enum SitePermissions {
    enum Kind: String, CaseIterable {
        case camera, microphone, location
        var name: String { rawValue.capitalized }
    }

    static func blockedOrigins(_ kind: Kind, defaults: UserDefaults = .standard) -> [String] {
        SitePolicy.entries(SitePolicy.Feature(rawValue: kind.rawValue)!, defaults: defaults).filter { $0.value == "block" }.keys.sorted()
    }

    static func isBlocked(_ kind: Kind, at url: URL, defaults: UserDefaults = .standard) -> Bool {
        SitePolicy.decision(SitePolicy.Feature(rawValue: kind.rawValue)!, at: url, defaults: defaults) == .block
    }

    static func setBlocked(_ blocked: Bool, kind: Kind, at url: URL, defaults: UserDefaults = .standard) {
        guard let origin = BrowsingSecurity.origin(url) else { return }
        SitePolicy.set(blocked ? .block : .ask, feature: SitePolicy.Feature(rawValue: kind.rawValue)!, origin: origin, defaults: defaults)
    }
}
