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

@Test func searchResultRecognitionCoversEveryEngine() {
    for engine in SearchEngine.allCases {
        #expect(AddressInput.isSearchURL(engine.url(for: "aero")))
    }
    #expect(!AddressInput.isSearchURL(URL(string: "https://example.com/search?q=aero")!))
}
