import Foundation
import Testing
@testable import Browser

@Test func deletingRecentVisitsPreservesAnOlderVisitToTheSameAddress() {
    let history = History(path: ":memory:")
    let url = URL(string: "https://example.test/")!
    let now = Date()
    history.visit(url, at: now.addingTimeInterval(-86_400))
    history.visit(url, at: now)
    #expect(history.visits().count == 2)
    history.clear(since: now.addingTimeInterval(-3600))
    #expect(history.visits().count == 1)
    #expect(history.suggestions(for: "example.test").map(\.url) == [url])
}

@Test func retentionRemovesOldAddressesAndNeverModeStopsRecording() {
    var days = 0
    let history = History(path: ":memory:", retention: { days })
    let now = Date()
    let older = URL(string: "https://older.example.test/")!
    let recent = URL(string: "https://recent.example.test/")!
    history.visit(older, at: now.addingTimeInterval(-100 * 86_400))
    history.visit(recent, at: now)
    days = 30
    #expect(history.suggestions(for: "example.test").map(\.url) == [recent])
    days = -1
    history.visit(recent)
    #expect(history.suggestions(for: "example.test").isEmpty)
}

@Test func clearingARangeKeepsAddressesLastVisitedBeforeIt() {
    let history = History(path: ":memory:")
    let now = Date()
    let older = URL(string: "https://older.example.test/")!
    history.visit(older, at: now.addingTimeInterval(-86_400))
    history.visit(URL(string: "https://recent.example.test/")!, at: now)
    history.clear(since: now.addingTimeInterval(-3600))
    #expect(history.suggestions(for: "example.test").map(\.url) == [older])
}
