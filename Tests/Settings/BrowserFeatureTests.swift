import Foundation
import Testing
@testable import Browser

@Test func customSearchEncodesWordsWithoutCreatingExtraQueryParameters() throws {
    let engine = CustomSearch.Engine(name: "Example", shortcut: "ex", template: "https://example.test/search?q=%s&source=browser")
    #expect(engine.isValid)
    let url = try #require(engine.url(for: "one & two=three+#four"))
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.first { $0.name == "q" }?.value == "one & two=three+#four")
    #expect(items.count == 2)
    #expect(!CustomSearch.Engine(name: "Bad", shortcut: "bad", template: "javascript:%s").isValid)
}

@Test func crashSnapshotsKeepWindowSelectionAndGroupsUntilExplicitlyCleared() throws {
    let suite = "snapshot-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot = SavedSession.WindowState(
        tabs: [
            .init(url: URL(string: "https://first.example.test")!, group: "Reading"),
            .init(url: URL(string: "https://second.example.test")!, group: nil),
        ], selected: 1, frame: nil, collapsedGroups: ["Reading"])
    SavedSession.saveWindows([snapshot], defaults: defaults)
    #expect(SavedSession.load(defaults: defaults) == [snapshot])
    #expect(SavedSession.load(defaults: defaults) == [snapshot])
    SavedSession.clear(defaults: defaults)
    #expect(SavedSession.load(defaults: defaults).isEmpty)
}

@MainActor @Test func secureDNSRejectsCleartextCredentialsAndInvalidBootstrapAddresses() {
    #expect(SecureDNS.validServer(URL(string: "https://resolver.example.test/dns-query")!, addresses: ["1.1.1.1", "2606:4700:4700::1111"]))
    #expect(!SecureDNS.validServer(URL(string: "http://resolver.example.test")!, addresses: ["1.1.1.1"]))
    #expect(!SecureDNS.validServer(URL(string: "https://user:password@resolver.example.test")!, addresses: ["1.1.1.1"]))
    #expect(!SecureDNS.validServer(URL(string: "https://resolver.example.test")!, addresses: ["not-an-address"]))
}
