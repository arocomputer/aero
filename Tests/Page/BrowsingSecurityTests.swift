import Foundation
import Testing
import WebKit
@testable import Browser

@Test func httpsFirstDoesNotUpgradeInternalPageSchemes() {
    for address in [
        "aero://settings", "aero://extensions", "webkit-extension://fixture/options.html", "about:blank", "http://localhost:8080",
    ] {
        #expect(BrowsingSecurity.httpsPolicy(for: URL(string: address)) == .keepAsRequested)
    }
    #expect(BrowsingSecurity.httpsPolicy(for: URL(string: "http://example.test")) == .userMediatedFallbackToHTTP)
}

@Test func onlyLocalDestinationsBypassHTTPSFirst() {
    for host in ["localhost", "dev.localhost", "printer.local", "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "[::1]", "[fd00::1]"]
    {
        #expect(BrowsingSecurity.isLocalDestination(URL(string: "http://\(host)/")))
    }
    for host in ["example.com", "localhost.evil.test", "printer.local.evil.test", "172.32.0.1", "8.8.8.8", "[2606:4700:4700::1111]"] {
        #expect(!BrowsingSecurity.isLocalDestination(URL(string: "http://\(host)/")))
    }
}

@Test func internalActionsRequireTheirOwnTopLevelPage() {
    let target = URL(string: "aero://settings/action/clear-history")!
    let source = URL(string: "aero://settings")!
    #expect(BrowsingSecurity.allowsInternalAction(target, source: source, isMainFrame: true, targetsMainFrame: true))
    #expect(!BrowsingSecurity.allowsInternalAction(target, source: source, isMainFrame: false, targetsMainFrame: true))
    #expect(!BrowsingSecurity.allowsInternalAction(target, source: source, isMainFrame: true, targetsMainFrame: false))
    for untrusted in ["https://settings/", "aero://extensions/", "aero://settings:99/", "aero://user@settings/", "about:blank"] {
        #expect(!BrowsingSecurity.allowsInternalAction(target, source: URL(string: untrusted), isMainFrame: true, targetsMainFrame: true))
    }
}

@Test func permissionDenialsAreScopedToSchemeHostAndPort() throws {
    let suite = "permission-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let site = URL(string: "https://example.test/call")!
    SitePermissions.setBlocked(true, kind: .camera, at: site, defaults: defaults)
    #expect(SitePermissions.isBlocked(.camera, at: URL(string: "https://example.test:443/other")!, defaults: defaults))
    for other in ["http://example.test", "https://example.test:8443", "https://sub.example.test"] {
        #expect(!SitePermissions.isBlocked(.camera, at: URL(string: other)!, defaults: defaults))
    }
    #expect(!SitePermissions.isBlocked(.microphone, at: site, defaults: defaults))
    SitePermissions.setBlocked(false, kind: .camera, at: site, defaults: defaults)
    #expect(!SitePermissions.isBlocked(.camera, at: site, defaults: defaults))
}

@MainActor @Test func trackerRulesRespectHostBoundariesAndExactSiteExceptions() throws {
    let source = try TrackerProtection.rules(domains: ["tracker.test"], exceptions: ["site.test"])
    let rules = try #require(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [[String: Any]])
    let block = try #require(rules.first?["trigger"] as? [String: Any])
    #expect(block["load-type"] as? [String] == ["third-party"])
    let pattern = try #require(block["url-filter"] as? String)
    let regex = try NSRegularExpression(pattern: pattern)
    for address in ["https://tracker.test/pixel", "http://sub.tracker.test:80/pixel"] {
        #expect(regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil)
    }
    for address in ["https://nottracker.test/pixel", "https://tracker.test.evil.test/", "https://site.test/tracker.test/"] {
        #expect(regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) == nil)
    }
    let exception = try #require(rules.last?["trigger"] as? [String: Any])
    let topPattern = try #require((exception["if-top-url"] as? [String])?.first)
    let top = try NSRegularExpression(pattern: topPattern)
    for address in ["https://site.test/", "http://site.test:8080/path"] {
        #expect(top.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil)
    }
    for address in ["https://site.test.evil.test/", "https://sub.site.test/", "https://site.test@evil.test/"] {
        #expect(top.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) == nil)
    }
}

@MainActor @Test func bundledTrackerListCompilesWithWebKit() async throws {
    let suite = "tracker-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let protection = TrackerProtection(defaults: defaults)
    try await protection.prepare(WKUserContentController())
    #expect(protection.isReady)
    let site = URL(string: "https://example.test/")!
    try await protection.setEnabled(false, for: site)
    #expect(!protection.isEnabled(for: site))
    #expect(protection.isEnabled(for: URL(string: "https://sub.example.test/")!))
}
