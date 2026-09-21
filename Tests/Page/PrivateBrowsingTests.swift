import AppKit
import Testing
import WebKit
@testable import Browser

@MainActor @Test func privateWindowsOverrideInheritedPersistentConfigurations() {
    _ = NSApplication.shared
    let window = WindowController(isPrivate: true)
    defer { window.close() }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let tab = window.openTab(configuration: configuration)
    #expect(!tab.recordsActivity)
    #expect(tab.webView.configuration.webExtensionController == nil)
    #expect(tab.webView.configuration.websiteDataStore === window.tabs[0].webView.configuration.websiteDataStore)
    window.registerWithExtensions()
    #expect(!window.isRegisteredWithExtensions)
}

@MainActor @Test func popupControllersDoNotShareMutableSitePolicies() {
    _ = NSApplication.shared
    let first = Tab(configuration: Tab.configuration(ephemeral: true))
    let second = Tab(configuration: first.webView.configuration)
    #expect(first.webView.configuration.userContentController !== second.webView.configuration.userContentController)
    #expect(first.webView.configuration.preferences !== second.webView.configuration.preferences)
}
