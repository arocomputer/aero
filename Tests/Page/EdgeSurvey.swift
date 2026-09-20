import AppKit
import Foundation
import Testing
import WebKit
@testable import Browser

/// Measures how often the probe names the color real pages show along their top edge. It loads each
/// site in a web view that is never put on screen, at the top and scrolled, and compares the probe's
/// answer with the dominant color of a snapshot of the top row. It needs the network and minutes, so
/// it only runs when asked: `AERO_SURVEY=1 ./x test --filter edgeSurvey`. Add sites with
/// `AERO_SURVEY_SITES=a.com,b.com`.
///
/// Read the result knowing what the snapshot cannot see off screen: it often leaves out sticky
/// headers and content revealed by animation, and a thin accent stripe along the top counts as the
/// "truth" though the probe rightly looks past it. A mismatch is a lead to look into, not a verdict.
private let defaultSites = [
    "apple.com", "github.com", "zoah.com", "stripe.com", "linear.app", "vercel.com", "nytimes.com", "en.wikipedia.org",
    "youtube.com", "reddit.com", "amazon.com", "bbc.com", "theverge.com", "medium.com", "notion.so", "figma.com",
    "developer.mozilla.org", "cnn.com", "google.com", "microsoft.com", "adobe.com", "atlassian.com", "gitlab.com",
    "npmjs.com", "rust-lang.org", "python.org", "go.dev", "swift.org", "developer.apple.com", "aws.amazon.com",
    "digitalocean.com", "netlify.com", "supabase.com", "framer.com", "webflow.com", "squarespace.com", "canva.com",
    "pinterest.com", "quora.com", "ebay.com", "etsy.com", "walmart.com", "ikea.com", "washingtonpost.com",
    "theguardian.com", "bloomberg.com", "wired.com", "arstechnica.com", "techcrunch.com",
]

private final class Reports: NSObject, WKScriptMessageHandler {
    var all: [String] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let text = message.body as? String { all.append(text) }
    }
}

private func rgb(_ color: NSColor?) -> [Int]? {
    guard let color = color?.usingColorSpace(.sRGB) else { return nil }
    return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
}

@MainActor private func topRow(of webView: WKWebView) async -> [Int]? {
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: 2)
    let image = try? await webView.takeSnapshot(configuration: configuration)
    return rgb(image?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(EdgeColor.dominant))
}

/// "match", "pixels" when the app would turn to WebKit's sample or a snapshot, or what differed.
@MainActor private func verdict(_ report: String?, _ webView: WKWebView, _ truth: [Int]?) -> String {
    guard let truth else { return "no snapshot" }
    guard let report else { return "NO REPORT" }
    let parts = (report.split(separator: "~").first ?? "").split(separator: "|")
    let answer = String(parts.first ?? "")
    if answer.hasPrefix("unknown") { return "pixels" }
    let said = answer == "page" ? rgb(webView.underPageBackgroundColor) : answer.split(separator: ",").compactMap { Int($0) }
    guard let said, said.count == 3 else { return "MISMATCH unreadable \(report)" }
    let off = zip(said, truth).map { abs($0 - $1) }.max() ?? 255
    return off <= (parts.count > 1 ? 40 : 24) ? "match" : "MISMATCH said \(said), top row \(truth)"
}

@MainActor private func survey(_ site: String) async -> [String] {
    let reports = Reports()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    // A window that is never shown counts as hidden, and the probe lets a hidden page wait.
    configuration.userContentController.addUserScript(
        WKUserScript(
            source: "Object.defineProperty(document, 'hidden', { get: () => false })",
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
    EdgeChangeRouter.install(in: configuration.userContentController, handler: reports)
    configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
    let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = webView
    webView.load(URLRequest(url: URL(string: "https://\(site)/")!))
    try? await Task.sleep(for: .seconds(9))
    let top = verdict(reports.all.last, webView, await topRow(of: webView))
    _ = try? await webView.evaluateJavaScript("scrollTo(0, 900); 0")
    try? await Task.sleep(for: .seconds(2.5))
    let scrolled = verdict(reports.all.last, webView, await topRow(of: webView))
    print(
        "SURVEY \(site.padding(toLength: 24, withPad: " ", startingAt: 0)) top: \(top) · scrolled: \(scrolled) [\(reports.all.last ?? "-")]"
    )
    return [top, scrolled]
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["AERO_SURVEY"] != nil))
func edgeSurvey() async {
    let extra = ProcessInfo.processInfo.environment["AERO_SURVEY_SITES"]?.split(separator: ",").map(String.init)
    let sites = extra ?? defaultSites
    var verdicts: [String] = []
    for start in stride(from: 0, to: sites.count, by: 8) {
        await withTaskGroup(of: [String].self) { group in
            for site in sites[start..<min(start + 8, sites.count)] { group.addTask { await survey(site) } }
            for await result in group { verdicts += result }
        }
    }
    let count = { (prefix: String) in verdicts.filter { $0.hasPrefix(prefix) }.count }
    print(
        "SURVEY of \(sites.count) sites, \(verdicts.count) checks: \(count("match")) match, \(count("pixels")) left to pixels, \(count("MISMATCH")) mismatch, \(count("NO REPORT") + count("no snapshot")) unread"
    )
}
