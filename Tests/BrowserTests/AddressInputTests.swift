import Foundation
import Testing
@testable import Browser

@Test(arguments: [
    ("nor.ma", "https://nor.ma"),
    ("dashboard.nor.ma/website/reviews?page=2", "https://dashboard.nor.ma/website/reviews?page=2"),
    ("http://example.com/a", "http://example.com/a"),
    ("localhost:3000/admin", "http://localhost:3000/admin"),
    ("192.168.1.1", "http://192.168.1.1"),
])
func addressesLoadDirectly(input: String, expected: String) {
    #expect(AddressInput.url(for: input)?.absoluteString == expected)
}

@Test(arguments: ["swift concurrency", "norma", "what is 3.5", "foo:bar", "1.5"])
func everythingElseIsASearch(input: String) throws {
    let url = try #require(AddressInput.url(for: input))
    #expect(AddressInput.isSearchURL(url))
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == input)
}

@Test func emptyInputGoesNowhere() {
    #expect(AddressInput.url(for: "  ") == nil)
}

@Test func displayDropsSchemeWwwAndTrailingSlash() {
    #expect(AddressInput.display(for: URL(string: "https://www.officecommun.com/")!) == "officecommun.com")
    #expect(AddressInput.display(for: URL(string: "https://nor.ma/journal/")!) == "nor.ma/journal")
}
