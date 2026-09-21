import ObjectiveC
import Testing
import WebKit

/// A configuration for pages loaded in a window that is never shown, which is how the scripts are
/// tested without raising windows on anyone's desk. Such a page counts as hidden, and two things
/// follow from that which have nothing to do with what is being tested: a script lets a hidden page
/// wait, and WebKit slows a hidden page's timers, more the busier the machine, which made these tests
/// time out on a loaded CI runner. The script's own world is told the page is visible, and WebKit is
/// asked not to throttle; the page itself is left alone.
@MainActor func offscreenPageConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    // Private preferences, set by selector and only where they exist; the tests run without them.
    for name in ["_setHiddenPageDOMTimerThrottlingEnabled:", "_setPageVisibilityBasedProcessSuppressionEnabled:"] {
        let selector = NSSelectorFromString(name)
        guard configuration.preferences.responds(to: selector), let method = class_getInstanceMethod(WKPreferences.self, selector)
        else { continue }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(configuration.preferences, selector, false)
    }
    configuration.userContentController.addUserScript(
        WKUserScript(
            source: "Object.defineProperty(document, 'hidden', { get: () => false })",
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
    return configuration
}

/// How long `settles` waits. Generous, since it only costs time when a test is failing anyway; while
/// iterating on a broken script, `AERO_TEST_TIMEOUT=3 ./x test` makes that cost bearable.
private let settleTimeout = Double(ProcessInfo.processInfo.environment["AERO_TEST_TIMEOUT"] ?? "") ?? 20

/// Runs one of the real injected scripts against a small page in a web view that is never put on
/// screen, and collects what the script reports. `install` is the script's own installer, so each test
/// exercises the same code the app ships rather than a copy of it. Waiting is by polling, because what
/// is being watched is a page painting rather than a promise.
@MainActor final class ScriptedPage: NSObject, WKScriptMessageHandler {
    private(set) var reports: [String] = []
    /// The page itself, for the survey, which compares a report with a snapshot of the top row.
    let webView: WKWebView
    private let window: NSWindow

    /// A page written here. `base` is the address it believes it was served from, which decides what
    /// its relative links resolve to.
    convenience init(
        _ html: String, base: String = "https://aero.example/", size: NSSize = NSSize(width: 1000, height: 700),
        install: (WKUserContentController, WKScriptMessageHandler) -> Void
    ) {
        self.init(size: size, ephemeral: false, install: install) { $0.loadHTMLString(html, baseURL: URL(string: base)) }
    }

    /// A real site, for the survey. It keeps nothing: the session goes with the page, so a survey never
    /// touches the browsing data a dev build holds. Sites are told a Safari version, because what a
    /// page shows along its top edge is often chosen by what it thinks it is running in.
    convenience init(
        loading url: URL, size: NSSize = NSSize(width: 1280, height: 800),
        install: (WKUserContentController, WKScriptMessageHandler) -> Void
    ) {
        self.init(size: size, ephemeral: true, install: install) { $0.load(URLRequest(url: url)) }
    }

    private init(
        size: NSSize, ephemeral: Bool, install: (WKUserContentController, WKScriptMessageHandler) -> Void,
        load: (WKWebView) -> Void
    ) {
        let configuration = offscreenPageConfiguration()
        if ephemeral {
            configuration.websiteDataStore = .nonPersistent()
            configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        }
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        install(configuration.userContentController, self)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        load(webView)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let report = message.body as? String { reports.append(report) }
    }

    /// Runs `script` in the page, as the page itself would.
    func run(_ script: String) async {
        _ = try? await webView.evaluateJavaScript(script + "; 0")
    }

    func loaded() async {
        for _ in 0..<200 where webView.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Whether the latest report came to satisfy `expected` in time.
    func settles(timeout: Double = settleTimeout, on expected: (String) -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let last = reports.last, expected(last) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func settles(on expected: String) async -> Bool {
        await settles { $0 == expected }
    }
}
