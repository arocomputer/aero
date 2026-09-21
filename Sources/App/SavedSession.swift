import Foundation

/// Opt-in crash snapshots contain web addresses, tab groups and window selection, never page forms.
/// The snapshot remains available until replaced so an unclean exit can restore the last saved state.
enum SavedSession {
    struct TabState: Codable, Equatable {
        let url: URL
        var group: String?
    }
    struct WindowState: Codable, Equatable {
        var tabs: [TabState]
        var selected: Int = 0
        var frame: String?
        var collapsedGroups: [String]?
    }

    static func save(_ windows: [[URL]], defaults: UserDefaults = .standard) {
        saveWindows(windows.map { WindowState(tabs: $0.map { TabState(url: $0) }) }, defaults: defaults)
    }

    static func saveWindows(_ windows: [WindowState], defaults: UserDefaults = .standard) {
        let cleaned = windows.map { window -> WindowState in
            var window = window
            window.tabs = window.tabs.filter { AddressInput.isWeb($0.url) }
            window.selected = min(max(0, window.selected), max(0, window.tabs.count - 1))
            return window
        }.filter { !$0.tabs.isEmpty }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(cleaned) else { return }
        if defaults.data(forKey: "SavedWindows.v2") != data { defaults.set(data, forKey: "SavedWindows.v2") }
        defaults.removeObject(forKey: "SavedSession")
    }

    static func load(defaults: UserDefaults = .standard) -> [WindowState] {
        if let data = defaults.data(forKey: "SavedWindows.v2"), let windows = try? JSONDecoder().decode([WindowState].self, from: data) {
            return windows.map { window in
                WindowState(
                    tabs: window.tabs.filter { AddressInput.isWeb($0.url) }, selected: window.selected, frame: window.frame,
                    collapsedGroups: window.collapsedGroups)
            }.filter { !$0.tabs.isEmpty }
        }
        let legacy = defaults.array(forKey: "SavedSession") as? [[String]] ?? []
        return legacy.map { WindowState(tabs: $0.compactMap(URL.init(string:)).filter(AddressInput.isWeb).map { TabState(url: $0) }) }
            .filter { !$0.tabs.isEmpty }
    }

    /// Explicitly consumes a snapshot when a caller wants one-shot restoration.
    static func take(defaults: UserDefaults = .standard) -> [[URL]] {
        let windows = load(defaults: defaults).map { $0.tabs.map(\.url) }
        clear(defaults: defaults)
        return windows
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "SavedSession")
        defaults.removeObject(forKey: "SavedWindows.v2")
    }
}
