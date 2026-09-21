import AppKit
import Foundation
import Testing
import WebKit
@testable import Browser

/// Supplies tab identity without creating a browser window or web view.
@MainActor private final class ExtensionTabFixture: NSObject, WKWebExtensionTab {}

@MainActor @Test func extensionInsertionSkipsEphemeralTabs() {
    #expect(WebExtensions.insertionIndex(0, visibility: [false, true, false, true]) == 1)
    #expect(WebExtensions.insertionIndex(1, visibility: [false, true, false, true]) == 3)
    #expect(WebExtensions.insertionIndex(2, visibility: [false, true, false, true]) == 4)
    #expect(WebExtensions.insertionIndex(NSNotFound, visibility: [false]) == 1)
}

@MainActor @Test func extensionWindowRejectsInvalidTransfersAndPrivateRequests() throws {
    _ = NSApplication.shared
    let suite = "extension-window-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = WebExtensions(defaults: defaults, directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
    #expect(throws: Never.self) { try manager.validateNewWindow(tabs: [], isPrivate: false) }
    #expect(throws: (any Error).self) { try manager.validateNewWindow(tabs: [ExtensionTabFixture()], isPrivate: false) }
    #expect(throws: (any Error).self) { try manager.validateNewWindow(tabs: [], isPrivate: true) }
    let source = WindowController(restorePins: false, startsEmpty: true)
    defer { source.close() }
    let tab = source.openTab(useNewTabOverride: false)
    #expect(throws: Never.self) { try manager.validateNewWindow(tabs: [tab], isPrivate: false) }
    #expect(throws: (any Error).self) { try manager.validateNewWindow(tabs: [tab, tab], isPrivate: false) }
}

@MainActor @Test func extensionFocusExcludesPrivateAndUnregisteredWindows() {
    _ = NSApplication.shared
    let ordinary = WindowController(restorePins: false, startsEmpty: true)
    let secret = WindowController(isPrivate: true, restorePins: false, startsEmpty: true)
    defer { ordinary.close(); secret.close() }
    #expect(ordinary.extensionFocusTarget == nil)
    ordinary.isRegisteredWithExtensions = true
    #expect(ordinary.extensionFocusTarget === ordinary)
    secret.isRegisteredWithExtensions = true
    #expect(secret.extensionFocusTarget == nil)
    ordinary.isRegisteredWithExtensions = false
    secret.isRegisteredWithExtensions = false
    #expect(ordinary.tabs.isEmpty)
}

@MainActor @Test func extensionTransferPreservesPageAndRepairsSelection() throws {
    _ = NSApplication.shared
    let source = WindowController(restorePins: false, startsEmpty: true)
    let destination = WindowController(restorePins: false, startsEmpty: true)
    let secret = WindowController(isPrivate: true, restorePins: false, startsEmpty: true)
    defer { source.close(); destination.close(); secret.close() }
    let moving = source.openTab(useNewTabOverride: false)
    let child = source.openTab(inBackground: true, useNewTabOverride: false)
    child.opener = moving
    let page = moving.webView
    #expect(!secret.transfer(moving, to: 0))
    #expect(moving.owner === source)
    #expect(destination.transfer(moving, to: 0))
    #expect(moving.webView === page)
    #expect(moving.owner === destination)
    #expect(source.active === child)
    #expect(child.opener == nil)
    #expect(destination.active === moving)
    #expect(source.tabs == [child])
    #expect(destination.tabs == [moving])
    #expect(!source.window!.isVisible && !destination.window!.isVisible && !secret.window!.isVisible)
    #expect(destination.transfer(child, to: 0))
    #expect(source.tabs.isEmpty)
    #expect(source.active == nil)
    #expect(destination.tabs == [child, moving])
}

@MainActor @Test func extensionParentMustBeLiveAndInSamePublicWindow() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"manifest_version":3,"name":"Parent Fixture","version":"1.0"}"#.utf8)
        .write(to: root.appendingPathComponent("manifest.json"))
    let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: root))
    let first = WindowController(restorePins: false, startsEmpty: true)
    let second = WindowController(restorePins: false, startsEmpty: true)
    defer { first.close(); second.close() }
    let parent = first.openTab(useNewTabOverride: false)
    let child = first.openTab(inBackground: true, useNewTabOverride: false)
    let foreign = second.openTab(useNewTabOverride: false)
    child.setParentTab(parent, for: context) { #expect($0 == nil) }
    #expect(child.parentTab(for: context) === parent)
    child.setParentTab(foreign, for: context) { #expect($0 != nil) }
    child.setParentTab(child, for: context) { #expect($0 != nil) }
    first.close(parent)
    #expect(child.parentTab(for: context) == nil)
    child.setParentTab(parent, for: context) { #expect($0 != nil) }
    child.setParentTab(nil, for: context) { #expect($0 == nil) }
}
