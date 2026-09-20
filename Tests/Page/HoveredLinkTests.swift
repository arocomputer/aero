import AppKit
import Testing
import WebKit
@testable import Browser

/// Runs the real script against a small page that is never put on screen, and collects the addresses
/// it reports as the pointer is moved by dispatching the events a pointer would cause.
@MainActor private final class HoveredPage: NSObject, WKScriptMessageHandler {
    private(set) var reports: [String] = []
    private let webView: WKWebView
    private let window: NSWindow

    init(_ html: String) {
        let configuration = offscreenPageConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        HoveredLink.install(in: configuration.userContentController, handler: self)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.loadHTMLString(html, baseURL: URL(string: "https://aero.example/docs/"))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let report = message.body as? String { reports.append(report) }
    }

    /// Moves the pointer onto the element `selector` finds, as the page sees it.
    func enter(_ selector: String) async {
        let script = "(\(selector)).dispatchEvent(new MouseEvent('mouseover', { bubbles: true, composed: true })); 0"
        _ = try? await webView.evaluateJavaScript(script)
    }

    func settles(on expected: String, timeout: Double = 20) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if reports.last == expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func loaded() async {
        for _ in 0..<200 where webView.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

@MainActor @Test func hoveringInsideALinkReportsWhereItLeadsNotWhatItSays() async {
    let page = HoveredPage("<a href='../legal?x=1'><b id=inner>https://bank.example/ is safe</b></a><p id=plain>text</p>")
    await page.loaded()
    await page.enter("document.getElementById('inner')")
    #expect(await page.settles(on: "https://aero.example/legal?x=1"))

    await page.enter("document.getElementById('plain')")
    #expect(await page.settles(on: ""))
}

@MainActor @Test func scriptLinksShowNothing() async {
    let page = HoveredPage("<a id=real href='/a'>a</a><a id=script href='javascript:void(0)'>b</a>")
    await page.loaded()
    await page.enter("document.getElementById('real')")
    #expect(await page.settles(on: "https://aero.example/a"))
    await page.enter("document.getElementById('script')")
    #expect(await page.settles(on: ""))
}

@MainActor @Test func linkInsideAWebComponentIsReported() async {
    let page = HoveredPage(
        """
        <site-nav></site-nav>
        <script>document.querySelector('site-nav').attachShadow({mode:'open'}).innerHTML = '<a href="/pricing"><span>Pricing</span></a>'</script>
        """)
    await page.loaded()
    await page.enter("document.querySelector('site-nav').shadowRoot.querySelector('span')")
    #expect(await page.settles(on: "https://aero.example/pricing"))
}
