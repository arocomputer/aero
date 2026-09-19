import Foundation
import Testing
@testable import Browser

private func history(visiting addresses: [String]) -> History {
    let history = History(path: ":memory:")
    addresses.forEach { history.visit(URL(string: $0)!) }
    return history
}

@Test func addressPrefixOutranksMoreVisitedSubstringMatch() {
    let history = history(visiting: [
        "https://dashboard.nor.ma/", "https://dashboard.nor.ma/", "https://dashboard.nor.ma/",
        "https://nor.ma/",
    ])
    #expect(history.suggestions(for: "n").map(\.display) == ["nor.ma", "dashboard.nor.ma"])
}

@Test func moreVisitedPageWinsAmongPrefixMatches() {
    let history = history(visiting: ["https://news.example/", "https://nor.ma/", "https://nor.ma/"])
    #expect(history.suggestions(for: "n").first?.display == "nor.ma")
}

@Test func matchesTitlesAndIgnoresTypedSchemeAndWww() {
    let history = history(visiting: ["https://nor.ma/"])
    history.setTitle("Norma — Block distracting apps", for: URL(string: "https://nor.ma/")!)

    #expect(history.suggestions(for: "distracting").first?.title == "Norma — Block distracting apps")
    #expect(history.suggestions(for: "https://www.nor").first?.display == "nor.ma")
}

@Test func likeWildcardsInTypedTextAreLiteral() {
    let history = history(visiting: ["https://nor.ma/"])
    #expect(history.suggestions(for: "%").isEmpty)
    #expect(history.suggestions(for: "n_r").isEmpty)
}

@Test func searchResultPagesAreNotRecorded() {
    let history = history(visiting: [AddressInput.searchURL(for: "norma").absoluteString])
    #expect(history.suggestions(for: "google").isEmpty)
}
