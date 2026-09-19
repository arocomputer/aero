import AppKit
import WebKit

/// Decides the color the tab strip takes on so the chrome reads as part of the page. The page reports
/// what should set it (see `EdgeChangeRouter.script` for which elements count): "r,g,b" when its styles
/// say, "page" when its own background should show, "unknown:<element>" when an image, gradient or
/// other painted content decides it.
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

    /// Works out which color the strip should take, from styles alone, painting nothing.
    ///
    /// Not everything that touches the top edge counts. A page like a feed has cards and columns
    /// scrolling under the strip; following those would flip the strip's color with every card. So at
    /// five points across the edge the script finds the element whose background shows there, and only
    /// two kinds can set the color. A pinned element, fixed or sticky, stays put while the page scrolls:
    /// a sticky header, or an app's sidebar. A plain colored column with a pinned layer in front of it
    /// counts too, which is how GitHub builds its sidebar. An invisible layer does not count, and neither
    /// does anything less than 12px tall at the edge: a site's loading bar is pinned and full width, and
    /// would otherwise turn the strip its color whenever a page loads slowly. A band spans nearly the full width: a hero, a full-bleed
    /// section, often just the page's backdrop. Pinned beats scrolling, a band beats a column, then the
    /// wider wins. Anything else, a card or a column passing by, leaves the page's own background.
    ///
    /// The report, sent when it changes, is "r,g,b", "page", or "unknown:<n>" when a band is an image,
    /// gradient, backdrop-filtered surface, non-sRGB color or other painted element, n numbering it so
    /// the native side can remember what it looked like. Ordinary translucent colors are composited
    /// through the elements behind them. A video never counts, and neither does a painted element
    /// narrower than a band, since a snapshot could not tell its part of the edge from the rest.
    ///
    /// Asking where elements are makes the page bring its layout up to date, which is real work on a
    /// busy page, so probing is kept rare: on load, resize and scroll only, at most ten times a second,
    /// and once more shortly after the last of them to catch a header that was still fading. It never
    /// listens to animations; a page full of them would otherwise be probed on every frame.
    static let script = """
        (() => {
            const painted = /^(IMG|CANVAS|PICTURE|SVG|IFRAME|EMBED|OBJECT)$/i;
            const numbers = new WeakMap(), pinned = new WeakMap();
            let last, count = 0, probeTimer = 0, settleTimer = 0, probedAt = 0;

            function unknown(element) {
                if (!numbers.has(element)) numbers.set(element, ++count);
                return 'unknown:' + numbers.get(element);
            }

            function isPinned(element) {
                if (!pinned.has(element)) {
                    let found = false;
                    for (let e = element; e && e !== document.documentElement && !found; e = e.parentElement) {
                        const position = getComputedStyle(e).position;
                        found = position === 'fixed' || position === 'sticky';
                    }
                    pinned.set(element, found);
                }
                return pinned.get(element);
            }

            // What shows at one point of the top edge: the answer, the element that owns it, and whether
            // it stays put. Sites often color a plain column and pin a transparent layer inside it, so the
            // owner also counts as pinned when something visible, pinned and no wider sits in front of it.
            function at(x) {
                let r = 0, g = 0, b = 0, a = 0, owner = null;
                const front = [];
                const result = (answer, element, isPainted) => {
                    const own = owner || element, width = own.getBoundingClientRect().width;
                    const stays = isPinned(own) || front.some(e => isPinned(e) && e.getBoundingClientRect().width <= width + 2);
                    return { answer, width, stays, isPainted };
                };
                for (const element of document.elementsFromPoint(x, 1)) {
                    // A sliver along the edge, a loading bar or an accent stripe, is not the top of the page.
                    const box = element.getBoundingClientRect();
                    if (box.bottom - Math.max(box.top, 0) < 12) continue;
                    if (element.tagName === 'VIDEO') return null;
                    if (painted.test(element.tagName)) return result(unknown(element), element, true);
                    const style = getComputedStyle(element);
                    const backdrop = style.backdropFilter || style.webkitBackdropFilter || 'none';
                    if (style.backgroundImage !== 'none' || backdrop !== 'none')
                        return result(unknown(element), element, true);
                    const color = style.backgroundColor;
                    if (!color.startsWith('rgb')) return result(unknown(element), element, true);
                    const [red, green, blue, alpha = 1] = color.match(/[\\d.]+/g).map(Number);
                    const cover = (1 - a) * alpha * Number(style.opacity);
                    if (!owner && cover >= 0.5) owner = element;
                    if (!owner && Number(style.opacity) > 0 && style.visibility !== 'hidden') front.push(element);
                    r += cover * red; g += cover * green; b += cover * blue; a += cover;
                    if (a > 0.99) return result([r, g, b].map(v => Math.round(v / a)).join(','), element, false);
                }
                // A transparent document canvas still paints in the system color scheme. Blend the
                // accumulated layers into that canvas instead of discarding their visible tint.
                if (a > 0 && owner) {
                    const dark = getComputedStyle(document.documentElement).colorScheme.includes('dark')
                        || matchMedia('(prefers-color-scheme: dark)').matches;
                    const canvas = dark ? 0 : 255;
                    return result([r, g, b].map(v => Math.round(v + (1 - a) * canvas)).join(','), owner, false);
                }
                return null;
            }

            function probe() {
                probeTimer = 0;
                probedAt = performance.now();
                // Pinned beats scrolling, since it stays; among equals a band beats a column, then the wider wins.
                let answer = 'page', best = 0;
                for (const f of [0.02, 0.25, 0.5, 0.75, 0.98]) {
                    const found = at(Math.floor(innerWidth * f));
                    if (!found) continue;
                    const isBand = found.width >= innerWidth * 0.9;
                    if (!isBand && (!found.stays || found.isPainted)) continue;
                    const rank = (found.stays ? 2 : 0) + (isBand ? 1 : 0) + found.width / (innerWidth * 10);
                    if (rank > best) { answer = found.answer; best = rank; }
                }
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
