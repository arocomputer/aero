import AppKit
import WebKit

/// Decides the color the tab strip takes on so the chrome reads as part of the page, wherever WebKit
/// does not name it itself (see `Tab.sampledHeaderColor`): before macOS 26, for headers that are
/// translucent or blurred, and for bands that are not pinned. The page reports
/// what should set it (see `EdgeChangeRouter.script` for which elements count): "r,g,b" when its styles
/// say, "page" when its own background should show, "unknown:<element>" when an image, gradient or
/// other painted content decides it. The element's name includes how it looks, so a header that turns
/// from a clear gradient into a dark one is a new name.
///
/// Only "unknown" needs pixels, and a snapshot makes the page paint on its main thread: tens of
/// milliseconds on a plain page, half a second on one full of canvases, during which the page freezes.
/// So snapshots are rationed hard: one per look of an element and `maxSnapshots` per page, taken only
/// once the page has loaded and both scrolling and reports have been quiet for `delay`. Until then,
/// and whenever that look is at the edge again, `color` is what is known, or stays what it was.
final class PageEdge {
    /// The color along the top edge; nil until known, and when the page's own background shows there.
    private(set) var color: NSColor?
    /// How opaque the header's own tint is when it blurs what is behind it; nil for a plain surface.
    private(set) var opacity: CGFloat?
    /// How long the page takes to reach `color`, when its header is fading there; 0 for at once.
    private(set) var glide: TimeInterval = 0
    /// Whether `color` was read from the page's styles, which is exact and current, rather than
    /// found in a snapshot or kept from before.
    var isFromStyles: Bool { color != nil && undecided == nil && kept == nil }

    /// A page that keeps changing its painted header can't make the strip freeze it over and over.
    static let maxSnapshots = 8

    private let delay: TimeInterval
    private let isLoading: () -> Bool
    private let isShown: () -> Bool
    private let snapshot: (@escaping (NSColor?) -> Void) -> Void
    private let onChange: () -> Void

    /// The latest "unknown" report, naming the element that decides the edge.
    private var undecided: String?
    /// What each element's one snapshot found, so coming back to it is instant.
    private var found: [String: NSColor] = [:]
    private var snapshotted: Set<String> = []
    private var pending: DispatchWorkItem?
    /// Ends a color kept across `reset(keepingColor:)` if the new page never reports.
    private var kept: DispatchWorkItem?

    /// `snapshot` supplies the dominant color along the top edge, or nil if it could not be read.
    /// `isShown` is whether a snapshot can and should be taken now: a hidden page can't be
    /// snapshotted, and the tab also says no while WebKit itself names the color.
    init(
        delay: TimeInterval = 0.5, isLoading: @escaping () -> Bool, isShown: @escaping () -> Bool,
        snapshot: @escaping (@escaping (NSColor?) -> Void) -> Void, onChange: @escaping () -> Void
    ) {
        (self.delay, self.isLoading, self.isShown, self.snapshot, self.onChange) = (delay, isLoading, isShown, snapshot, onChange)
    }

    /// Takes one report from the page.
    func report(_ full: String) {
        kept?.cancel()
        kept = nil
        // "<answer>|<opacity>~<ms>": the opacity when the header is a blurring material, the time
        // when it is fading to this answer.
        let timed = full.split(separator: "~", maxSplits: 1)
        glide = timed.count == 2 ? (Double(timed[1]) ?? 0) / 1000 : 0
        let parts = (timed.first ?? "").split(separator: "|", maxSplits: 1)
        let report = String(parts.first ?? "")
        let material = parts.count == 2 ? Double(parts[1]).map { CGFloat($0) } : nil
        if material != opacity {
            opacity = material
            onChange()
        }
        guard report.hasPrefix("unknown") else {
            cancelPending()
            undecided = nil
            let parts = report.split(separator: ",").compactMap { Double($0) }
            return show(
                parts.count == 3
                    ? NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
                    : nil)
        }
        // A page that animates repeats itself constantly. A repeat must not restart the wait, or the
        // snapshot would never come while the animation runs.
        if report == undecided { return }
        undecided = report
        if let known = found[report] { show(known) }
        if snapshotted.contains(report) || snapshotted.count >= Self.maxSnapshots { cancelPending() } else { schedule() }
    }

    /// Called while the user scrolls, to keep a waiting snapshot from landing mid-scroll.
    func userIsScrolling() {
        if pending != nil { schedule() }
    }

    /// Called when the page is shown again: a snapshot that came due while it was hidden could not be
    /// taken, and the page will not repeat its report.
    func resume() {
        if let undecided, !snapshotted.contains(undecided), pending == nil { schedule() }
    }

    /// Forgets everything; the page was replaced. Moving within a site, the header is usually the same,
    /// so `keepingColor` leaves the strip as it is until the new page's first report instead of
    /// flashing the page's background in between. A page that never reports loses the color after 2s.
    func reset(keepingColor: Bool = false) {
        cancelPending()
        kept?.cancel()
        kept = nil
        (undecided, found, snapshotted) = (nil, [:], [])
        guard keepingColor, color != nil else {
            opacity = nil
            return show(nil)
        }
        let work = DispatchWorkItem { [weak self] in self?.show(nil) }
        kept = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func show(_ new: NSColor?) {
        guard new != color else { return }
        color = new
        onChange()
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func schedule() {
        cancelPending()
        let work = DispatchWorkItem { [weak self] in self?.takeSnapshot() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func takeSnapshot() {
        pending = nil
        guard let element = undecided, isShown() else { return }
        if isLoading() { return schedule() }
        snapshotted.insert(element)
        snapshot { [weak self] color in
            guard let self, let color else { return }
            found[element] = color
            // Only shown if that element still decides the edge; otherwise it waits for its return.
            if element == undecided { show(color) }
        }
    }
}

/// Receives the injected script's reports of what is along the page's top edge and passes each to the
/// tab whose page sent it. One stateless instance serves every web view, so no tab is retained by its
/// own configuration and script-opened tabs are covered without registering anything again.
final class EdgeChangeRouter: NSObject, WKScriptMessageHandler {
    static let shared = EdgeChangeRouter()
    static let name = "edge"

    /// The probe that works out which color the strip should take, from styles alone. It lives in
    /// EdgeProbe.js beside this file, with the rules it follows, and posts to the handler `name`.
    static let script: String = {
        let url = Bundle.module.url(forResource: "EdgeProbe", withExtension: "js")!
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Adds the probe and its message handler to a configuration's content controller.
    static func install(in controller: WKUserContentController, handler: WKScriptMessageHandler = shared) {
        controller.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        controller.add(handler, contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let report = message.body as? String else { return }
        (message.webView?.navigationDelegate as? Tab)?.edge.report(report)
    }
}
