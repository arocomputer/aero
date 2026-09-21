import Foundation

/// Recently closed ordinary tabs are kept in memory only. Private activity never enters this list.
@MainActor enum ClosedTabs {
    struct Entry {
        let url: URL
        let state: Any?
        let group: String?
    }
    private(set) static var entries: [Entry] = []
    static func remember(_ tab: Tab) {
        guard tab.recordsActivity, let url = tab.url, AddressInput.isWeb(url) else { return }
        entries.insert(Entry(url: url, state: tab.webView.interactionState, group: tab.groupName), at: 0)
        if entries.count > 25 { entries.removeLast() }
    }
    static func take() -> Entry? { entries.isEmpty ? nil : entries.removeFirst() }
    static func clear() { entries.removeAll() }
}
