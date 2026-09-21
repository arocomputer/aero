import AppKit
import Foundation
import Testing
import WebKit

@testable import Browser

/// Measures how often the script names the color real pages show along their top edge. It loads each
/// site in a web view that is never put on screen, at the top and scrolled, and compares the script's
/// answer with the dominant color of a snapshot of the top row. It needs the network and minutes, so
/// it only runs when asked: `./x survey`, or `./x survey --filter tintSurvey` with
/// `AERO_SURVEY_SITES=a.com,b.com` to name your own.
///
/// Read the result knowing what the snapshot cannot see off screen: it often leaves out sticky
/// headers and content revealed by animation, and a thin accent stripe along the top counts as the
/// "truth" though the script rightly looks past it. A mismatch is a lead to look into, not a verdict.
///
/// It fails only on silence. A page that loaded and painted but drew no report at all means the script
/// did not run or threw, which is a fault in Aero rather than a judgement about a site; mismatches are
/// printed and counted, and left for a person to read.
private let defaultSites = [
    "apple.com", "github.com", "zoah.com", "stripe.com", "linear.app", "vercel.com", "nytimes.com", "en.wikipedia.org",
    "youtube.com", "reddit.com", "amazon.com", "bbc.com", "theverge.com", "medium.com", "notion.so", "figma.com",
    "developer.mozilla.org", "cnn.com", "google.com", "microsoft.com", "adobe.com", "atlassian.com", "gitlab.com",
    "npmjs.com", "rust-lang.org", "python.org", "go.dev", "swift.org", "developer.apple.com", "aws.amazon.com",
    "digitalocean.com", "netlify.com", "supabase.com", "framer.com", "webflow.com", "squarespace.com", "canva.com",
    "pinterest.com", "quora.com", "ebay.com", "etsy.com", "walmart.com", "ikea.com", "washingtonpost.com",
    "theguardian.com", "bloomberg.com", "wired.com", "arstechnica.com", "techcrunch.com",
]

private func rgb(_ color: NSColor?) -> [Int]? {
    guard let color = color?.usingColorSpace(.sRGB) else { return nil }
    return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
}

@MainActor private func topRow(of webView: WKWebView) async -> [Int]? {
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: 2)
    let image = try? await webView.takeSnapshot(configuration: configuration)
    return rgb(image?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(DominantColor.of))
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
    guard let url = URL(string: "https://\(site)/") else { return [] }
    let page = ScriptedPage(loading: url) { controller, handler in
        TintRouter.install(in: controller, handler: handler)
    }
    try? await Task.sleep(for: .seconds(9))
    let top = verdict(page.reports.last, page.webView, await topRow(of: page.webView))
    await page.run("scrollTo(0, 900)")
    try? await Task.sleep(for: .seconds(2.5))
    let scrolled = verdict(page.reports.last, page.webView, await topRow(of: page.webView))
    print(
        "SURVEY \(site.padding(toLength: 24, withPad: " ", startingAt: 0)) top: \(top) · scrolled: \(scrolled) [\(page.reports.last ?? "-")]"
    )
    return [top, scrolled]
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["AERO_SURVEY"] != nil))
func tintSurvey() async {
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
    #expect(count("NO REPORT") == 0, "a page painted but the script said nothing about it")
}
