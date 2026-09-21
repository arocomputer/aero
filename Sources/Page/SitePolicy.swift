import Foundation

/// Browser defaults and exact-origin overrides. Private-window overrides live in the window, not here.
enum SitePolicy {
    enum Feature: String, CaseIterable {
        case camera, microphone, location, javaScript, popups, images, downloads, media
        var name: String {
            switch self {
            case .javaScript: "JavaScript"
            case .popups: "Pop-up windows"
            case .images: "Remote images"
            case .downloads: "Downloads"
            case .media: "Audio and video playback"
            default: rawValue.capitalized
            }
        }
        var initial: Decision {
            switch self {
            case .camera, .microphone, .location: .ask
            case .popups: .block
            default: .allow
            }
        }
        var supportsAsk: Bool { [.camera, .microphone, .location, .downloads].contains(self) }
    }
    enum Decision: String, CaseIterable { case ask, allow, block }

    /// An embedded frame cannot bypass a denial or approval requirement on the containing website.
    static func combined(_ top: Decision, _ frame: Decision) -> Decision {
        if top == .block || frame == .block { return .block }
        return top == .allow && frame == .allow ? .allow : .ask
    }

    static func defaultDecision(_ feature: Feature, defaults: UserDefaults = .standard) -> Decision {
        Decision(rawValue: defaults.string(forKey: "SiteDefault.\(feature.rawValue)") ?? "") ?? feature.initial
    }

    static func entries(_ feature: Feature, defaults: UserDefaults = .standard) -> [String: String] {
        var entries: [String: String] = [:]
        for origin in defaults.stringArray(forKey: "BlockedSitePermissions.\(feature.rawValue)") ?? [] {
            entries[origin] = Decision.block.rawValue
        }
        entries.merge(defaults.dictionary(forKey: "SitePolicy.\(feature.rawValue)") as? [String: String] ?? [:]) { _, new in new }
        return entries
    }

    static func decision(_ feature: Feature, at url: URL, defaults: UserDefaults = .standard) -> Decision {
        guard let origin = BrowsingSecurity.origin(url) else { return .block }
        return entries(feature, defaults: defaults)[origin].flatMap(Decision.init(rawValue:))
            ?? defaultDecision(feature, defaults: defaults)
    }

    static func setDefault(_ decision: Decision, for feature: Feature) {
        guard decision != .ask || feature.supportsAsk else { return }
        UserDefaults.standard.set(decision.rawValue, forKey: "SiteDefault.\(feature.rawValue)")
    }

    static func set(_ decision: Decision?, feature: Feature, origin: String, defaults: UserDefaults = .standard) {
        guard let url = URL(string: origin), let origin = BrowsingSecurity.origin(url), decision != .ask || feature.supportsAsk else {
            return
        }
        var entries = entries(feature, defaults: defaults)
        entries[origin] = decision?.rawValue
        defaults.removeObject(forKey: "BlockedSitePermissions.\(feature.rawValue)")
        defaults.set(entries, forKey: "SitePolicy.\(feature.rawValue)")
    }
}
