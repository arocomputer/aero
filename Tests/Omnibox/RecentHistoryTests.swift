import Foundation
import Testing
@testable import Browser

@Test func recentHistoryUsesVisitTimeRatherThanFrequencyAndHonorsRetention() {
    var days = 0
    let history = History(path: ":memory:", retention: { days })
    let old = URL(string: "https://older.example.test/")!
    let new = URL(string: "https://recent.example.test/")!
    let now = Date()
    for _ in 0..<3 { history.visit(old, at: now.addingTimeInterval(-40 * 86_400)) }
    history.visit(new, at: now)
    history.setTitle("Recent fixture", for: new)
    #expect(history.recent(limit: 1).map(\.url) == [new])
    #expect(history.recent().map(\.url) == [new, old])
    days = 30
    #expect(history.recent().map(\.title) == ["Recent fixture"])
}
