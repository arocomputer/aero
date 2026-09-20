import AppKit
import Testing
import WebKit
@testable import Browser

/// Runs the real script against a small page in a web view that is never put on screen, and
/// collects what it reports.
@MainActor private final class TintedPage: NSObject, WKScriptMessageHandler {
    private(set) var reports: [String] = []
    private let webView: WKWebView
    private let window: NSWindow

    private static let base = """
        <style>body{margin:0;background:#fff} .hero{height:700px;background:rgb(29,78,216)} main{height:3000px}
        header{position:fixed;top:0;left:0;right:0;height:64px}</style>
        """

    init(_ html: String) {
        let configuration = offscreenPageConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        TintRouter.install(in: configuration.userContentController, handler: self)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.loadHTMLString(Self.base + html, baseURL: URL(string: "https://tint.example/"))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let report = message.body as? String { reports.append(report) }
    }

    func run(_ script: String) async {
        _ = try? await webView.evaluateJavaScript(script + "; 0")
    }

    /// Waits until the latest report satisfies `expected`, and returns whether it came in time. The
    /// limit is generous because it only costs time when a test is failing anyway.
    func settles(timeout: Double = 20, on expected: (String) -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let last = reports.last, expected(last) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

private let togglesSolidOnScroll =
    "<script>addEventListener('scroll',()=>document.querySelector('header').classList.toggle('solid',scrollY>50))</script>"

@MainActor @Test func blurredHeaderIsReadThroughToWhatIsBehindIt() async {
    let page = TintedPage(
        """
        <style>header{backdrop-filter:blur(12px)} header.solid{background:rgb(0,0,0)}</style>
        <header></header><div class=hero></div><main></main>\(togglesSolidOnScroll)
        """)
    #expect(await page.settles { $0 == "29,78,216" })
    await page.run("scrollTo(0, 1500)")
    #expect(await page.settles { $0 == "0,0,0" })
}

@MainActor @Test func fadingHeaderReportsWhereItIsGoingAndForHowLong() async throws {
    let page = TintedPage(
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
    let page = TintedPage(
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
    // Corners tight enough that every sample along the top lands on the card, none on the page.
    let card = "<div style='margin:0 12px;height:600px;border-radius:6px;background:rgb(40,44,52)'></div><main></main>"
    let inset = TintedPage("<style>body{background:rgb(244,244,244)}</style>" + card)
    #expect(await inset.settles { $0 == "page" })

    let bleed = TintedPage("<div style='height:600px;background:rgb(40,44,52)'></div><main></main>")
    #expect(await bleed.settles { $0 == "40,44,52" })
}

@MainActor @Test func headerInsideAWebComponentIsRead() async {
    let page = TintedPage(
        """
        <top-banner style="display:block;position:sticky;top:0;height:64px"></top-banner><main></main>
        <script>document.querySelector('top-banner').attachShadow({mode:'open'}).innerHTML =
            '<div style="height:64px;background:rgb(73,1,134)"></div>'</script>
        """)
    #expect(await page.settles { $0 == "73,1,134" })
}

@MainActor @Test func dialogScrimOverTheWholePageIsLeftToPixels() async {
    let page = TintedPage(
        """
        <header style="background:#000" inert></header><main inert></main>
        <div style="position:fixed;inset:0;background:rgba(0,0,0,.4)"></div>
        """)
    #expect(await page.settles { $0.hasPrefix("unknown:") })
}

@MainActor @Test func scrimHiddenFromHitTestingIsRead() async {
    let page = TintedPage(
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
    let page = TintedPage(
        """
        <style>header{backdrop-filter:blur(20px);background:rgba(250,250,252,.8)} .hero{background-image:radial-gradient(#123,#456)}</style>
        <header></header><div class=hero></div><main></main>
        """)
    #expect(await page.settles { $0 == "250,250,252" })
}

@MainActor @Test func verticalGradientCountsAsItsTopStop() async {
    let page = TintedPage(
        "<style>header{background-image:linear-gradient(rgb(17,17,17), rgb(51,51,51))}</style><header></header><main></main>")
    #expect(await page.settles { $0 == "17,17,17" })
}

@MainActor @Test func headerPaintedByAPseudoElementIsRead() async {
    let page = TintedPage(
        "<style>header::before{content:'';position:absolute;top:0;left:0;width:100%;height:64px;background:rgb(0,90,40);z-index:-1}</style><header></header><main></main>"
    )
    #expect(await page.settles { $0 == "0,90,40" })
}

@MainActor @Test func headerRenderedAfterLoadIsNoticedWithoutScrolling() async {
    let page = TintedPage(
        """
        <div class=hero></div><main></main>
        <script>addEventListener('load',()=>setTimeout(()=>{const h=document.createElement('header');h.style.background='#000';document.body.prepend(h)},400))</script>
        """)
    #expect(await page.settles { $0 == "0,0,0" })
}

@MainActor @Test func themeSwitchedByAClickIsNoticedWithoutScrolling() async {
    let page = TintedPage("<style>header{background:#fff} .dark header{background:#000}</style><header></header><main></main>")
    #expect(await page.settles { $0 == "255,255,255" })
    await page.run("dispatchEvent(new Event('pointerdown')); setTimeout(() => document.documentElement.classList.add('dark'), 100)")
    #expect(await page.settles { $0 == "0,0,0" })
}

@MainActor @Test func colorsOutsideRGBNotationAreConvertedInsteadOfSnapshotted() async {
    let page = TintedPage("<style>header{background:oklch(0.35 0.2 264)}</style><header></header><main></main>")
    #expect(await page.settles { !$0.hasPrefix("unknown") && $0 != "page" })
    let parts = page.reports.last?.split(separator: ",").compactMap { Int($0) } ?? []
    #expect(parts.count == 3 && parts[2] > parts[0] && parts[2] > parts[1])
}

@MainActor @Test func paintedHeaderGetsANewNameWhenItsLookChanges() async throws {
    let page = TintedPage(
        """
        <style>header{background-image:radial-gradient(#0000,#0000)} header.solid{background-image:radial-gradient(#000,#111)}</style>
        <header></header><div class=hero></div><main></main>\(togglesSolidOnScroll)
        """)
    #expect(await page.settles { $0.hasPrefix("unknown:1:") })
    let first = try #require(page.reports.last)
    await page.run("scrollTo(0, 1500)")
    #expect(await page.settles { $0.hasPrefix("unknown:1:") && $0 != first })
}
