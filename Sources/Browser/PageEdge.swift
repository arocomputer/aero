import AppKit
import WebKit

/// Decides the color along a page's top edge, which the tab strip takes on so the chrome reads as part
/// of the page. The page reports what is there (see `EdgeChangeRouter.script`): "r,g,b" when its styles
/// say, "page" when nothing there has a background of its own, "unknown:<element>" when an image,
/// gradient or other painted content decides it.
///
/// Only "unknown" needs pixels, and a snapshot makes the page paint on its main thread: tens of
/// milliseconds on a plain page, half a second on one full of canvases, during which the page freezes.
/// So snapshots are rationed hard: one per element per page, taken only once the page has loaded and
/// both scrolling and reports have been quiet for `delay`. Until then, and whenever that element is at
/// the edge again, `color` is what is known, or stays what it was.
final class PageEdge {
    /// The color along the top edge; nil until known, and when the page's own background shows there.
    private(set) var color: NSColor?

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

    /// `snapshot` supplies the dominant color along the top edge, or nil if it could not be read.
    /// `isShown` is whether the page is on screen; a hidden page can't be snapshotted.
    init(
        delay: TimeInterval = 0.5, isLoading: @escaping () -> Bool, isShown: @escaping () -> Bool,
        snapshot: @escaping (@escaping (NSColor?) -> Void) -> Void, onChange: @escaping () -> Void
    ) {
        (self.delay, self.isLoading, self.isShown, self.snapshot, self.onChange) = (delay, isLoading, isShown, snapshot, onChange)
    }

    /// Takes one report from the page.
    func report(_ report: String) {
        guard report.hasPrefix("unknown") else {
            cancelPending()
            undecided = nil
            let parts = report.split(separator: ",").compactMap { Double($0) }
            return show(parts.count == 3 ? NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1) : nil)
        }
        // A page that animates repeats itself constantly. A repeat must not restart the wait, or the
        // snapshot would never come while the animation runs.
        if report == undecided { return }
        undecided = report
        if let known = found[report] { show(known) }
        if snapshotted.contains(report) { cancelPending() } else { schedule() }
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

    /// Forgets everything; the page was replaced.
    func reset() {
        cancelPending()
        (undecided, found, snapshotted) = (nil, [:], [])
        show(nil)
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

    /// Works out the color along the top edge from styles alone, painting nothing. At three points
    /// across the edge it composites the backgrounds of the elements there, front to back, until opaque,
    /// and reports the most common answer when it changes: "r,g,b", or "page" when nothing there has a
    /// background or a video is playing there, or "unknown:<n>" when an image, gradient, non-sRGB color
    /// or other painted element decides it, n numbering that element so the native side can remember
    /// what it looked like.
    ///
    /// Asking where elements are makes the page bring its layout up to date, which is real work on a
    /// busy page, so probing is kept rare: on load, resize and scroll only, at most ten times a second,
    /// and once more shortly after the last of them to catch a header that was still fading. It never
    /// listens to animations; a page full of them would otherwise be probed on every frame.
    static let script = """
        (() => {
            const painted = /^(IMG|CANVAS|PICTURE|SVG|IFRAME|EMBED|OBJECT)$/i;
            const numbers = new WeakMap();
            let last, count = 0, probeTimer = 0, settleTimer = 0, probedAt = 0;

            function unknown(element) {
                if (!numbers.has(element)) numbers.set(element, ++count);
                return 'unknown:' + numbers.get(element);
            }

            function at(x) {
                let r = 0, g = 0, b = 0, a = 0;
                for (const element of document.elementsFromPoint(x, 1)) {
                    if (element.tagName === 'VIDEO') return 'page';
                    if (painted.test(element.tagName)) return unknown(element);
                    const style = getComputedStyle(element);
                    if (style.backgroundImage !== 'none') return unknown(element);
                    const color = style.backgroundColor;
                    if (!color.startsWith('rgb')) return unknown(element);
                    const [red, green, blue, alpha = 1] = color.match(/[\\d.]+/g).map(Number);
                    const cover = (1 - a) * alpha * Number(style.opacity);
                    r += cover * red; g += cover * green; b += cover * blue; a += cover;
                    if (a > 0.99) return [r, g, b].map(v => Math.round(v / a)).join(',');
                }
                return 'page';
            }

            function probe() {
                probeTimer = 0;
                probedAt = performance.now();
                const counts = {};
                for (const f of [0.2, 0.5, 0.8]) {
                    const answer = at(Math.floor(innerWidth * f));
                    counts[answer] = (counts[answer] || 0) + 1;
                }
                const answer = Object.keys(counts).sort((p, q) => counts[q] - counts[p])[0];
                if (answer !== last) webkit.messageHandlers.\(name).postMessage(answer);
                last = answer;
            }

            function request() {
                if (!probeTimer) probeTimer = setTimeout(probe, Math.max(0, 100 - (performance.now() - probedAt)));
                clearTimeout(settleTimer);
                settleTimer = setTimeout(probe, 400);
            }

            for (const type of ['scroll', 'resize', 'load', 'DOMContentLoaded'])
                addEventListener(type, request, { passive: true, capture: true });
        })();
        """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let report = message.body as? String else { return }
        (message.webView?.navigationDelegate as? Tab)?.edge.report(report)
    }
}
