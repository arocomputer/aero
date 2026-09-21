import Foundation
import Testing
@testable import Browser

@Test func sitePolicyOverridesAreScopedAndCanReturnToDefaults() throws {
    let suite = "site-policy-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("block", forKey: "SiteDefault.camera")
    let url = URL(string: "https://example.test/")!
    #expect(SitePolicy.decision(.camera, at: url, defaults: defaults) == .block)
    SitePolicy.set(.allow, feature: .camera, origin: "https://example.test", defaults: defaults)
    #expect(SitePolicy.decision(.camera, at: url, defaults: defaults) == .allow)
    #expect(SitePolicy.decision(.camera, at: URL(string: "http://example.test/")!, defaults: defaults) == .block)
    SitePolicy.set(nil, feature: .camera, origin: "https://example.test", defaults: defaults)
    #expect(SitePolicy.decision(.camera, at: url, defaults: defaults) == .block)
}

@Test func aFrameGrantCannotOverrideTheContainingSitesDevicePolicy() {
    #expect(SitePolicy.combined(.block, .allow) == .block)
    #expect(SitePolicy.combined(.allow, .block) == .block)
    #expect(SitePolicy.combined(.ask, .allow) == .ask)
    #expect(SitePolicy.combined(.allow, .allow) == .allow)
}
