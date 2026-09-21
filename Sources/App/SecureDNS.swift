import AppKit
import Network
import NetworkExtension
import Security

/// Uses macOS's encrypted-DNS configuration rather than intercepting browser TLS connections.
/// This is explicitly system-wide and requires the DNS-settings entitlement and user activation in macOS.
@MainActor final class SecureDNS {
    /// The resolver values shown in the editor and saved back to macOS without losing custom details.
    struct Configuration: Equatable {
        let url: URL
        let addresses: [String]

        var provider: String {
            Self.presets.first { $0.value == self }?.key ?? "custom"
        }

        static let presets: [String: Configuration] = [
            "cloudflare": .init(url: URL(string: "https://cloudflare-dns.com/dns-query")!, addresses: ["1.1.1.1", "1.0.0.1"]),
            "google": .init(url: URL(string: "https://dns.google/dns-query")!, addresses: ["8.8.8.8", "8.8.4.4"]),
            "quad9": .init(url: URL(string: "https://dns.quad9.net/dns-query")!, addresses: ["9.9.9.9", "149.112.112.112"]),
        ]
    }

    static let shared = SecureDNS()
    private(set) var status = "DNS follows macOS network settings."
    private(set) var configuration: Configuration?
    var selection: String { configuration?.provider ?? "system" }
    private var changing = false
    private var observer: NSObjectProtocol?

    var hasEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
            let values = SecTaskCopyValueForEntitlement(task, "com.apple.developer.networking.networkextension" as CFString, nil)
                as? [String]
        else { return false }
        return values.contains("dns-settings")
    }

    static func validServer(_ url: URL, addresses: [String]) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
            && !addresses.isEmpty && addresses.allSatisfy { IPv4Address($0) != nil || IPv6Address($0) != nil }
    }

    /// Restores the saved endpoint and bootstrap addresses for editing, or clears them when removed.
    func restore(_ settings: NEDNSSettings?) {
        guard let dns = settings as? NEDNSOverHTTPSSettings, let url = dns.serverURL else {
            configuration = nil
            return
        }
        configuration = Configuration(url: url, addresses: dns.servers)
    }

    /// Resolves an editor selection into the exact values to save; system DNS is handled by removal.
    static func resolver(_ provider: String, customURL: URL?, addresses: [String]) throws -> Configuration {
        if let preset = Configuration.presets[provider] { return preset }
        guard provider == "custom" else { throw NSError(domain: "SecureDNS", code: 3) }
        guard let customURL, validServer(customURL, addresses: addresses) else {
            throw NSError(
                domain: "SecureDNS", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Provide an HTTPS resolver URL and valid bootstrap IP addresses."])
        }
        return Configuration(url: customURL, addresses: addresses)
    }

    func load() async {
        guard hasEntitlement else {
            status = "DNS follows macOS. Configuring encrypted DNS requires a signed build with Apple's DNS-settings entitlement."
            return
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .NEDNSSettingsConfigurationDidChange, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    await self?.load()
                    (NSApp.keyWindow?.windowController as? WindowController)?.refreshLibrary("settings")
                }
            }
        }
        do {
            let manager = NEDNSSettingsManager.shared()
            try await manager.loadFromPreferences()
            restore(manager.dnsSettings)
            guard let configuration else {
                status = "No encrypted-DNS configuration is installed by this browser."
                return
            }
            status =
                manager.isEnabled
                ? "macOS has enabled DNS over HTTPS via \(configuration.url.host ?? "the selected provider")."
                : "The encrypted-DNS configuration is saved. Enable it in macOS Network settings."
        } catch { status = error.localizedDescription }
    }

    func configure(_ provider: String, customURL: URL? = nil, addresses: [String] = []) async throws {
        guard hasEntitlement, !changing else {
            throw NSError(
                domain: "SecureDNS", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "DNS configuration is unavailable or another change is in progress."])
        }
        changing = true
        defer { changing = false }
        let manager = NEDNSSettingsManager.shared()
        try await manager.loadFromPreferences()
        if provider == "system" {
            try await manager.removeFromPreferences()
            await load()
            return
        }
        let configuration = try Self.resolver(provider, customURL: customURL, addresses: addresses)
        let settings = NEDNSOverHTTPSSettings(servers: configuration.addresses)
        settings.serverURL = configuration.url
        settings.matchDomains = [""]
        manager.localizedDescription = "\(appName) encrypted DNS"
        manager.dnsSettings = settings
        manager.onDemandRules = nil
        try await manager.saveToPreferences()
        await load()
    }
}
