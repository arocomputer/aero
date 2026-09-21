import Foundation
import Testing
@testable import Browser

@Test func templateValuesCannotExpandIntoBundledScripts() {
    let name = BrowserPage.escape("{{script}}<b>Sample</b>")
    let html = BrowserPage.render("Settings", values: ["appName": name])
    #expect(html.contains("<title>{{script}}&lt;b&gt;Sample&lt;/b&gt; Settings</title>"))
    #expect(!html.contains("<b>Sample</b>"))
}

@Test func savedSessionsExcludeNonWebPagesAndAreConsumedOnce() throws {
    let suite = "session-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let web = URL(string: "https://example.test/")!
    SavedSession.save([[web, URL(string: "aero://settings")!, URL(string: "file:///private/fixture")!], []], defaults: defaults)
    #expect(SavedSession.take(defaults: defaults) == [[web]])
    #expect(SavedSession.take(defaults: defaults).isEmpty)
}
