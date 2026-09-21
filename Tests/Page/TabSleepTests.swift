import AppKit
import Testing
import WebKit

@testable import Browser

/// A tab holding a page, hidden long enough to sleep, and not in any window. The page is written here
/// rather than fetched, so the rules are tested without the network; a page loaded this way still has
/// the address its base URL gives it, which is what the rules read.
@MainActor private func hiddenTab(at address: String = "https://aero.example/page", hiddenFor seconds: TimeInterval = 3600) async -> Tab {
    let url = URL(string: address)!
    let tab = Tab()
    tab.load(url)
    tab.webView.loadHTMLString("<title>A page</title>", baseURL: url)
    for _ in 0..<200 where tab.webView.url == nil || tab.webView.isLoading {
        try? await Task.sleep(for: .milliseconds(25))
    }
    tab.hiddenSince = Date().addingTimeInterval(-seconds)
    return tab
}

@MainActor @Test func aTabHiddenLongEnoughGivesUpItsPage() async {
    let tab = await hiddenTab()
    #expect(tab.sleepBlocker(hiddenFor: Tab.sleepAfter) == nil)
}

@MainActor @Test func aTabBeingLookedAtOrJustPutDownKeepsItsPage() async {
    let showing = await hiddenTab()
    let content = NSView()
    content.addSubview(showing.webView)
    #expect(showing.sleepBlocker(hiddenFor: Tab.sleepAfter) == .onScreen)

    let recent = await hiddenTab(hiddenFor: 60)
    #expect(recent.sleepBlocker(hiddenFor: Tab.sleepAfter) == .hiddenTooRecently)
    // The memory-pressure path asks for a shorter wait, and the same tab may sleep then.
    #expect(recent.sleepBlocker(hiddenFor: 30) == nil)
}

@MainActor @Test func aPinnedTabKeepsItsPage() async {
    let tab = await hiddenTab()
    tab.pinnedURL = URL(string: "https://aero.example/page")
    #expect(tab.sleepBlocker(hiddenFor: Tab.sleepAfter) == .pinned)
}

/// A page opened by another page's script keeps its page whatever else is true: its opener holds a
/// handle to it and may be waiting to hear back.
@MainActor @Test func aTabOpenedByAScriptKeepsItsPage() async {
    let tab = Tab(configuration: Tab.configuration())
    tab.webView.loadHTMLString("<title>Opened</title>", baseURL: URL(string: "https://aero.example/popup"))
    for _ in 0..<200 where tab.webView.url == nil || tab.webView.isLoading {
        try? await Task.sleep(for: .milliseconds(25))
    }
    tab.hiddenSince = Date().addingTimeInterval(-3600)
    #expect(tab.sleepBlocker(hiddenFor: Tab.sleepAfter) == .openedByScript)
}

/// Sleeping keeps an address to come back to. A blank tab and one showing an app page have none worth
/// keeping, and reloading the latter would not be free.
@MainActor @Test func aTabWithNoWebPageToComeBackToKeepsIt() async {
    let blank = Tab()
    blank.hiddenSince = Date().addingTimeInterval(-3600)
    #expect(blank.sleepBlocker(hiddenFor: Tab.sleepAfter) == .blank)

    let local = await hiddenTab(at: "file:///tmp/aero-test/page.html")
    #expect(local.sleepBlocker(hiddenFor: Tab.sleepAfter) == .notAWebPage)
}
