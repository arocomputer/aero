import AppKit
import Foundation
import Testing
import WebKit
@testable import Browser

@MainActor @Test func disabledExtensionsStayInstalledAcrossReloadAndCanBeRemoved() async throws {
    _ = NSApplication.shared
    let suite = "extension-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    try Data(#"{"manifest_version":3,"name":"Fixture Extension","version":"1.0"}"#.utf8)
        .write(to: source.appendingPathComponent("manifest.json"))
    let directory = root.appendingPathComponent("installed", isDirectory: true)
    let manager = WebExtensions(defaults: defaults, directory: directory)
    try await manager.install(from: source)
    let context = try #require(manager.contexts.first)
    context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: "storage"))
    context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: "tabs"))
    #expect(manager.controller.extensionContexts.contains(context))
    try manager.setEnabled(false, for: context)
    #expect(manager.contexts.count == 1)
    #expect(!manager.controller.extensionContexts.contains(context))

    let restored = WebExtensions(defaults: defaults, directory: directory)
    await restored.loadInstalled()
    let disabled = try #require(restored.contexts.first)
    #expect(disabled.grantedPermissions.keys.contains(WKWebExtension.Permission(rawValue: "storage")))
    #expect(disabled.deniedPermissions.keys.contains(WKWebExtension.Permission(rawValue: "tabs")))
    #expect(!restored.isEnabled(disabled))
    #expect(!restored.controller.extensionContexts.contains(disabled))
    try restored.setEnabled(true, for: disabled)
    #expect(restored.controller.extensionContexts.contains(disabled))
    try restored.setEnabled(false, for: disabled)
    try restored.remove(disabled)
    #expect(restored.contexts.isEmpty)
    let removed = WebExtensions(defaults: defaults, directory: directory)
    await removed.loadInstalled()
    #expect(removed.contexts.isEmpty)
}

@MainActor @Test func unavailableInstallationsRemainRemovable() async throws {
    _ = NSApplication.shared
    let suite = "missing-extension-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let id = UUID().uuidString.lowercased()
    defaults.set(try JSONSerialization.data(withJSONObject: [["id": id, "filename": "missing.extension"]]), forKey: "extensions.v1")
    let manager = WebExtensions(defaults: defaults, directory: directory)
    await manager.loadInstalled()
    #expect(manager.contexts.isEmpty)
    #expect(manager.failedInstallations.map(\.id) == [id])
    manager.removeFailedInstallation(id)
    let restored = WebExtensions(defaults: defaults, directory: directory)
    await restored.loadInstalled()
    #expect(restored.failedInstallations.isEmpty)
}
