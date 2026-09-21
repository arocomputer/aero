import AppKit
import Testing
import WebKit

@testable import Browser

/// A page running the real tint script; see `ScriptedPage`. The shared styles give every page a white
/// body, a tall blue hero, a page long enough to scroll and a fixed header to dress up.
@MainActor private func tinted(_ html: String) -> ScriptedPage {
    let base = """
        <style>body{margin:0;background:#fff} .hero{height:700px;background:rgb(29,78,216)} main{height:3000px}
        header{position:fixed;top:0;left:0;right:0;height:64px}</style>
        """
    return ScriptedPage(base + html, base: "https://tint.example/") { controller, handler in
        TintRouter.install(in: controller, handler: handler)
    }
}

private let togglesSolidOnScroll =
    "<script>addEventListener('scroll',()=>document.querySelector('header').classList.toggle('solid',scrollY>50))</script>"

@MainActor @Test func blurredHeaderIsReadThroughToWhatIsBehindIt() async {
    let page = tinted(
        """
        <style>header{backdrop-filter:blur(12px)} header.solid{background:rgb(0,0,0)}</style>
        <header></header><div class=hero></div><main></main>\(togglesSolidOnScroll)
        """)
    #expect(await page.settles { $0 == "29,78,216" })
    await page.run("scrollTo(0, 1500)")
    #expect(await page.settles { $0 == "0,0,0" })
}

@MainActor @Test func fadingHeaderReportsWhereItIsGoingAndForHowLong() async throws {
    let page = tinted(
        """
        <style>header{background:rgb(255,255,255);transition:background-color .3s} header.solid{background:rgb(0,0,0)}</style>
        <header></header><main></main>\(togglesSolidOnScroll)
        """)
    #expect(await page.settles { $0 == "255,255,255" })
    await page.run("scrollTo(0, 1500)")
    #expect(await page.settles { $0.hasPrefix("0,0,0~") })
    let fade = try #require(page.reports.last?.split(separator: "~").last?.split(separator: ",", maxSplits: 1))
    let time = try #require(Int(fade[0]))
    #expect(time > 100 && time <= 300)
    #expect(fade.last == "ease")
}

@MainActor @Test func headerFadedInAsAPseudoElementReportsWhereItIsGoing() async {
    let page = tinted(
        """
        <style>header::after{content:'';position:absolute;inset:0;background:rgb(0,0,0);opacity:0;transition:opacity .2s}
        header.solid::after{opacity:1}</style>
        <header></header><div class=hero></div><main></main>\(togglesSolidOnScroll)
        """)
    #expect(await page.settles { $0 == "29,78,216" })
    await page.run("scrollTo(0, 1500)")
    #expect(await page.settles { $0.hasPrefix("0,0,0~") })
}

@MainActor @Test func heroSetInFromTheSidesIsACardNotABand() async {
    // Corners tight enough that every sample along the top lands on the card, none on the page, and
    // a page too short to scroll: a classic scrollbar, which a Mac with no trackpad always shows,
    // would narrow the page and move the last sample off the card.
    let card = "<div style='margin:0 12px;height:400px;border-radius:6px;background:rgb(40,44,52)'></div>"
    let inset = tinted("<style>body{background:rgb(244,244,244)}</style>" + card)
    #expect(await inset.settles { $0 == "page" })

    let bleed = tinted("<div style='height:400px;background:rgb(40,44,52)'></div>")
    #expect(await bleed.settles { $0 == "40,44,52" })
}

@MainActor @Test func clearNavFloatingOverCardsDoesNotMakeThemCount() async {
    // A clear fixed nav whose inner container is narrower than the card beneath it, over a flat card
    // set in from the sides; white pills inside the card pass under the nav as the page scrolls.
    let page = tinted(
        """
        <style>body{background:#fff} header{height:64px} header div{margin:0 auto;width:700px;height:64px}
        .card{margin:16px 16px 0;height:2600px;border-radius:28px 28px 0 0;background:rgb(245,245,245)}
        .pills{padding:300px 60px 0;display:flex;gap:8px} .pills b{flex:1;height:40px;background:#fff}</style>
        <header><div></div></header><div class=card><div class=pills><b></b><b></b><b></b></div></div>
        """)
    #expect(await page.settles { $0 == "255,255,255" || $0 == "page" })
    for y in [40, 320, 360] {
        await page.run("scrollTo(0, \(y))")
        try? await Task.sleep(for: .milliseconds(700))
    }
    // The card never took the strip, with pills under the nav or without: no flicker.
    #expect(page.reports.allSatisfy { $0 == "255,255,255" || $0 == "page" })
}

@MainActor @Test func columnWithAPinnedLayerInsideItCounts() async {
    let page = tinted(
        """
        <style>.side{position:absolute;left:0;top:0;width:300px;height:3000px;background:rgb(20,30,40)}
        .side div{position:sticky;top:0;height:700px}</style>
        <div class=side><div></div></div><main></main>
        """)
    #expect(await page.settles { $0 == "20,30,40" })
}

@MainActor @Test func headerInsideAWebComponentIsRead() async {
    let page = tinted(
        """
        <top-banner style="display:block;position:sticky;top:0;height:64px"></top-banner><main></main>
        <script>document.querySelector('top-banner').attachShadow({mode:'open'}).innerHTML =
            '<div style="height:64px;background:rgb(73,1,134)"></div>'</script>
        """)
    #expect(await page.settles { $0 == "73,1,134" })
}

@MainActor @Test func dialogScrimOverTheWholePageIsLeftToPixels() async {
    let page = tinted(
        """
        <header style="background:#000" inert></header><main inert></main>
        <div style="position:fixed;inset:0;background:rgba(0,0,0,.4)"></div>
        """)
    #expect(await page.settles { $0.hasPrefix("unknown:") })
}

@MainActor @Test func scrimHiddenFromHitTestingIsRead() async {
    let page = tinted(
        """
        <style>body{background:rgb(15,15,14)} header{position:sticky}
        .scrim{position:absolute;inset:0 0 auto 0;height:130px;z-index:-1;pointer-events:none}
        .scrim div{position:absolute;inset:0} .blur{backdrop-filter:blur(16px)}
        .tint{background:linear-gradient(to bottom, color-mix(in srgb, rgb(15,15,14) 88%, transparent) 0%, transparent 100%)}</style>
        <header><div class=scrim><div class=blur></div><div class=tint></div></div></header><main></main>
        """)
    #expect(await page.settles { $0 == "15,15,14" })
}

@MainActor @Test func glassHeaderOverAnImageAnswersWithItsOwnTint() async {
    let page = tinted(
        """
        <style>header{backdrop-filter:blur(20px);background:rgba(250,250,252,.8)} .hero{background-image:radial-gradient(#123,#456)}</style>
        <header></header><div class=hero></div><main></main>
        """)
    #expect(await page.settles { $0 == "250,250,252" })
}

@MainActor @Test func verticalGradientCountsAsItsTopStop() async {
    let page = tinted(
        "<style>header{background-image:linear-gradient(rgb(17,17,17), rgb(51,51,51))}</style><header></header><main></main>")
    #expect(await page.settles { $0 == "17,17,17" })
}

@MainActor @Test func headerPaintedByAPseudoElementIsRead() async {
    let page = tinted(
        "<style>header::before{content:'';position:absolute;top:0;left:0;width:100%;height:64px;background:rgb(0,90,40);z-index:-1}</style><header></header><main></main>"
    )
    #expect(await page.settles { $0 == "0,90,40" })
}

@MainActor @Test func headerRenderedAfterLoadIsNoticedWithoutScrolling() async {
    let page = tinted(
        """
        <div class=hero></div><main></main>
        <script>addEventListener('load',()=>setTimeout(()=>{const h=document.createElement('header');h.style.background='#000';document.body.prepend(h)},400))</script>
        """)
    #expect(await page.settles { $0 == "0,0,0" })
}

@MainActor @Test func themeSwitchedByAClickIsNoticedWithoutScrolling() async {
    let page = tinted("<style>header{background:#fff} .dark header{background:#000}</style><header></header><main></main>")
    #expect(await page.settles { $0 == "255,255,255" })
    await page.run("dispatchEvent(new Event('pointerdown')); setTimeout(() => document.documentElement.classList.add('dark'), 100)")
    #expect(await page.settles { $0 == "0,0,0" })
}

@MainActor @Test func colorsOutsideRGBNotationAreConvertedInsteadOfSnapshotted() async {
    let page = tinted("<style>header{background:oklch(0.35 0.2 264)}</style><header></header><main></main>")
    #expect(await page.settles { !$0.hasPrefix("unknown") && $0 != "page" })
    let parts = page.reports.last?.split(separator: ",").compactMap { Int($0) } ?? []
    #expect(parts.count == 3 && parts[2] > parts[0] && parts[2] > parts[1])
}

@MainActor @Test func paintedHeaderGetsANewNameWhenItsLookChanges() async throws {
    let page = tinted(
        """
        <style>header{background-image:radial-gradient(#0000,#0000)} header.solid{background-image:radial-gradient(#000,#111)}</style>
        <header></header><div class=hero></div><main></main>\(togglesSolidOnScroll)
        """)
    #expect(await page.settles { $0.hasPrefix("unknown:1:") })
    let first = try #require(page.reports.last)
    await page.run("scrollTo(0, 1500)")
    #expect(await page.settles { $0.hasPrefix("unknown:1:") && $0 != first })
}
