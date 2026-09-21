import AppKit
import Testing
import WebKit

@testable import Browser

/// A page running the real hovered-link script; see `ScriptedPage`.
@MainActor private func hovering(_ html: String) -> ScriptedPage {
    ScriptedPage(html, base: "https://aero.example/docs/", size: NSSize(width: 800, height: 600)) { controller, handler in
        HoveredLink.install(in: controller, handler: handler)
    }
}

/// Moves the pointer onto the element `selector` finds, as the page sees it.
@MainActor private func enter(_ selector: String, on page: ScriptedPage) async {
    await page.run("(\(selector)).dispatchEvent(new MouseEvent('mouseover', { bubbles: true, composed: true }))")
}

@MainActor @Test func hoveringInsideALinkReportsWhereItLeadsNotWhatItSays() async {
    let page = hovering("<a href='../legal?x=1'><b id=inner>https://bank.example/ is safe</b></a><p id=plain>text</p>")
    await page.loaded()
    await enter("document.getElementById('inner')", on: page)
    #expect(await page.settles(on: "https://aero.example/legal?x=1"))

    await enter("document.getElementById('plain')", on: page)
    #expect(await page.settles(on: ""))
}

@MainActor @Test func scriptLinksShowNothing() async {
    let page = hovering("<a id=real href='/a'>a</a><a id=script href='javascript:void(0)'>b</a>")
    await page.loaded()
    await enter("document.getElementById('real')", on: page)
    #expect(await page.settles(on: "https://aero.example/a"))
    await enter("document.getElementById('script')", on: page)
    #expect(await page.settles(on: ""))
}

@MainActor @Test func linkInsideAWebComponentIsReported() async {
    let page = hovering(
        """
        <site-nav></site-nav>
        <script>document.querySelector('site-nav').attachShadow({mode:'open'}).innerHTML = '<a href="/pricing"><span>Pricing</span></a>'</script>
        """)
    await page.loaded()
    await enter("document.querySelector('site-nav').shadowRoot.querySelector('span')", on: page)
    #expect(await page.settles(on: "https://aero.example/pricing"))
}
