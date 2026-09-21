import Foundation
import WebKit

/// Durable WebKit grants and denials. Expired entries are discarded when restoring a context.
struct ExtensionPermissions: Codable {
    let granted: [String: Date]
    let denied: [String: Date]
    let grantedSites: [String: Date]
    let deniedSites: [String: Date]
    let requestedAllHosts: Bool

    @MainActor init(_ context: WKWebExtensionContext) {
        granted = Dictionary(uniqueKeysWithValues: context.grantedPermissions.map { ($0.key.rawValue, $0.value) })
        denied = Dictionary(uniqueKeysWithValues: context.deniedPermissions.map { ($0.key.rawValue, $0.value) })
        grantedSites = Dictionary(uniqueKeysWithValues: context.grantedPermissionMatchPatterns.map { ($0.key.string, $0.value) })
        deniedSites = Dictionary(uniqueKeysWithValues: context.deniedPermissionMatchPatterns.map { ($0.key.string, $0.value) })
        requestedAllHosts = context.hasRequestedOptionalAccessToAllHosts
    }

    @MainActor func restore(into context: WKWebExtensionContext, now: Date = Date()) {
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: granted.filter { $0.value > now }.map {
                (WKWebExtension.Permission(rawValue: $0.key), $0.value)
            })
        context.deniedPermissions = Dictionary(
            uniqueKeysWithValues: denied.filter { $0.value > now }.map {
                (WKWebExtension.Permission(rawValue: $0.key), $0.value)
            })
        func patterns(_ values: [String: Date]) -> [WKWebExtension.MatchPattern: Date] {
            var result: [WKWebExtension.MatchPattern: Date] = [:]
            for (string, expiry) in values where expiry > now {
                if let pattern = try? WKWebExtension.MatchPattern(string: string) { result[pattern] = expiry }
            }
            return result
        }
        context.grantedPermissionMatchPatterns = patterns(grantedSites)
        context.deniedPermissionMatchPatterns = patterns(deniedSites)
        context.hasRequestedOptionalAccessToAllHosts = requestedAllHosts
    }
}
