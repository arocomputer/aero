import Foundation

/// The addresses of the pinned tabs, kept in user defaults; every new window opens with them.
enum PinnedTabs {
    static var urls: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "pins") ?? []).compactMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue.map(\.absoluteString), forKey: "pins") }
    }
}
