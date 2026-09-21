import Foundation
import WebKit

/// Compiles bundled or signed updated tracker domains into WebKit rules before navigation without
/// making network requests here. ProtectionList verifies updates; Scripts/trackers.py refreshes the bundle.
/// Exceptions match the exact top-level host, including its port variants, and remain on this Mac.
/// Public WKContentRuleList APIs expose no blocked-request callbacks or counts.
@MainActor final class TrackerProtection {
    static let shared = TrackerProtection()
    private let defaults: UserDefaults
    private var preparation: Task<WKContentRuleList, Error>?
    private var installed: WKContentRuleList?
    private var changing = false
    private var generation = 0
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private(set) var isReady = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var exceptions: Set<String> { Set(defaults.stringArray(forKey: "TrackerExceptions") ?? []) }

    func isEnabled(for url: URL) -> Bool { Settings.trackerBlocking && !exceptions.contains(url.host?.lowercased() ?? "") }

    /// New views, including restored and script-opened tabs, inherit already compiled protection.
    func installIfReady(in controller: WKUserContentController) {
        guard Settings.trackerBlocking, let installed, !controllers.contains(controller) else { return }
        controller.add(installed)
        controllers.add(controller)
    }

    /// Installs protection before allowing the first request, rather than racing a background compile.
    func prepare(_ controller: WKUserContentController) async throws {
        if !Settings.trackerBlocking {
            if let installed { controller.remove(installed) }
            controllers.remove(controller)
            return
        }
        if controllers.contains(controller) { return }
        let generation = generation
        let list: WKContentRuleList
        if let installed {
            list = installed
        } else {
            if preparation == nil {
                let exceptions = exceptions
                preparation = Task { try await Self.compile(exceptions: exceptions) }
            }
            do {
                list = try await preparation!.value
                if generation != self.generation { return try await prepare(controller) }
                installed = list
                isReady = true
            } catch {
                preparation = nil
                throw error
            }
        }
        if Settings.trackerBlocking, !controllers.contains(controller) {
            controller.add(list)
            controllers.add(controller)
        }
    }

    /// Replaces only our rule list, preserving extension rules. A failed compile keeps the old policy.
    func setEnabled(_ enabled: Bool, for url: URL) async throws {
        guard !changing else { throw NSError(domain: "BrowserProtection", code: 2) }
        changing = true
        defer { changing = false }
        guard let host = url.host?.lowercased(), AddressInput.isWeb(url) else { return }
        var updated = exceptions
        if enabled { updated.remove(host) } else { updated.insert(host) }
        let list = try await Self.compile(exceptions: updated)
        for controller in controllers.allObjects {
            if let installed { controller.remove(installed) }
            controller.add(list)
        }
        installed = list
        generation += 1
        preparation = nil
        isReady = true
        defaults.set(updated.sorted(), forKey: "TrackerExceptions")
    }

    /// Compiles before persisting a signed replacement, so a failed update cannot remove working protection.
    func replaceDomains(_ domains: [String], persist: () throws -> Void) async throws {
        guard !changing else { throw NSError(domain: "BrowserProtection", code: 2) }
        changing = true
        defer { changing = false }
        let list = try await Self.compile(exceptions: exceptions, domains: domains)
        try persist()
        for controller in controllers.allObjects {
            if let installed { controller.remove(installed) }
            controller.add(list)
        }
        generation += 1
        preparation = nil
        installed = list
        isReady = true
    }

    /// Host-anchored rules block third-party requests, leaving direct visits and first-party use alone.
    static func rules(domains: [String], exceptions: Set<String>) throws -> String {
        var rules: [[String: Any]] = domains.map { domain in
            [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: domain) + "[/:]",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        if !exceptions.isEmpty {
            rules.append([
                "trigger": [
                    "url-filter": ".*",
                    "if-top-url": exceptions.sorted().map {
                        "^https?://" + NSRegularExpression.escapedPattern(for: $0) + "(:[0-9]+)?/"
                    },
                ],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func compile(exceptions: Set<String>, domains: [String]? = nil) async throws -> WKContentRuleList {
        let domains = try domains ?? ProtectionList.current().domains
        let source = try rules(domains: domains, exceptions: exceptions)
        guard
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "browser-trackers", encodedContentRuleList: source)
        else { throw NSError(domain: "BrowserProtection", code: 1) }
        return list
    }
}
