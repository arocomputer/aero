import Foundation
import Testing
@testable import Browser

@Test(arguments: SearchEngine.allCases)
func searchEnginesEncodeQueries(_ engine: SearchEngine) throws {
    let url = engine.url(for: "swift webkit & appkit")
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first(where: { $0.name == "q" })?.value == "swift webkit & appkit")
    #expect(engine.owns(url))
}

/// Every engine recognizing its own result pages is pinned above, which is what keeps searches out of
/// history. The other half of that rule is that an ordinary page which happens to look like a search
/// is still recorded.
@Test func aPageThatMerelyLooksLikeASearchIsStillHistory() {
    #expect(!AddressInput.isSearchURL(URL(string: "https://example.com/search?q=aero")!))
}
