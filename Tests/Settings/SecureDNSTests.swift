import Foundation
import NetworkExtension
import Testing
@testable import Browser

/// Exercises saved resolver editing entirely in memory, without reading or changing system DNS.
@MainActor struct SecureDNSTests {
    @Test(arguments: [
        ("https://cloudflare-dns.com/custom-query", ["1.1.1.1", "1.0.0.1"]),
        ("https://dns.google:8443/dns-query", ["8.8.8.8", "8.8.4.4"]),
        ("https://dns.quad9.net/dns-query", ["9.9.9.10", "149.112.112.10"]),
        ("https://resolver.example.test/dns-query", ["192.0.2.1", "2001:db8::1"]),
    ])
    func customResolverSurvivesEditing(endpoint: String, addresses: [String]) throws {
        let settings = NEDNSOverHTTPSSettings(servers: addresses)
        settings.serverURL = URL(string: endpoint)!
        let dns = SecureDNS()
        dns.restore(settings)

        #expect(dns.selection == "custom")
        let restored = try #require(dns.configuration)
        // Use the editor's text representation when saving the restored configuration.
        let saved = try SecureDNS.resolver(
            dns.selection, customURL: URL(string: restored.url.absoluteString),
            addresses: restored.addresses.joined(separator: ", ").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
        #expect(saved.url == settings.serverURL)
        #expect(saved.addresses == addresses)
    }

    @Test(arguments: ["cloudflare", "google", "quad9"])
    func presetSurvivesReload(provider: String) throws {
        let preset = try SecureDNS.resolver(provider, customURL: nil, addresses: [])
        let settings = NEDNSOverHTTPSSettings(servers: preset.addresses)
        settings.serverURL = preset.url
        let dns = SecureDNS()
        dns.restore(settings)

        #expect(dns.selection == provider)
        #expect(dns.configuration == preset)
    }

    @Test func removingConfigurationClearsEditorValues() {
        let settings = NEDNSOverHTTPSSettings(servers: ["192.0.2.1"])
        settings.serverURL = URL(string: "https://resolver.example.test/dns-query")!
        let dns = SecureDNS()
        dns.restore(settings)
        dns.restore(nil)

        #expect(dns.selection == "system")
        #expect(dns.configuration == nil)
    }
}
