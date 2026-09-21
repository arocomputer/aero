import AppKit
import Testing
import WebKit

@testable import Browser

/// A reload is meant to look as if nothing moved, which rests on noting something near the top of the
/// viewport that can be found again afterwards. These run the real script that picks it; lining the
/// page back up afterwards needs a reload to test and is left to looking at the app.
@MainActor private func anchor(of page: ScriptedPage, scrolledTo offset: Int) async -> [String: Any] {
    await page.run("scrollTo(0, \(offset))")
    try? await Task.sleep(for: .milliseconds(200))
    let result = try? await page.webView.callAsyncJavaScript(
        ReloadHold.noteAnchor, arguments: [:], in: nil, contentWorld: .defaultClient)
    return (result as? [String: Any]) ?? [:]
}

@MainActor private func scrollable(_ body: String) async -> ScriptedPage {
    let page = ScriptedPage("<style>body{margin:0}.tall{height:2000px}</style>" + body) { _, _ in }
    await page.loaded()
    return page
}

@MainActor @Test func aPageAtItsTopNeedsNoAnchor() async {
    let page = await scrollable("<h2 id=mark>Section</h2><div class=tall></div>")
    #expect(await anchor(of: page, scrolledTo: 0).isEmpty)
}

@MainActor @Test func theAnchorIsSomethingNearTheTopThatCanBeFoundAgain() async {
    let page = await scrollable(
        #"<div class=tall></div><section id=mark style="margin:0;height:300px">Section</section><div class=tall></div>"#)
    let found = await anchor(of: page, scrolledTo: 1900)
    #expect(found["id"] as? String == "mark")
    // It is noted where it sits, so the reloaded page can be scrolled to put it back there.
    #expect(found["top"] as? Double == 100)
}

/// Lining up an element taller than the viewport would not correct a shift that happens inside it, so
/// it is not worth noting and the page is left to restore its own position.
@MainActor @Test func anElementTallerThanTheViewportIsNotAnAnchor() async {
    let page = await scrollable("<div class=tall id=huge></div>")
    #expect(await anchor(of: page, scrolledTo: 900).isEmpty)
}
