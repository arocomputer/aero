import AppKit
import WebKit

/// Makes a reload look like nothing moved. Sites restore their own scroll position after a reload and
/// keep shifting their layout for a second or so afterwards, so a plain reload shows the top of the
/// page, jumps back, and then nudges the text. Every browser shows that. This hides it:
///
/// 1. Before reloading it notes an anchor, an element near the top of the viewport and where it sits,
///    and takes a still picture of the page, which covers the web view.
/// 2. The page reloads underneath. Once it has loaded and its structure, size and scroll position have
///    been quiet for a moment, the script scrolls so the anchor sits exactly where it was.
/// 3. The picture fades out. For a couple of seconds more the page stays locked to the anchor, so a late
///    layout shift is corrected in the frame it happens. Scrolling by hand ends the hold at once.
///
/// `chromeColor` is the strip's color from when the picture was taken. The tab shows it for as long as
/// the hold lasts, so the strip never follows the half-loaded page underneath.
final class ReloadHold {
    let chromeColor: NSColor?
    private weak var webView: WKWebView?
    private let anchor: [String: Any]
    private let cover: Cover
    private let onEnd: () -> Void
    private var hasEnded = false

    /// Notes the anchor and takes the picture, then hands back a hold already covering `webView`, or nil
    /// when the page could not be pictured. Call `webView.reload()` from `ready`, then `pageCommitted()`
    /// when the new page commits and `end()` if the load fails. `onEnd` runs once, when the hold is over.
    static func begin(in webView: WKWebView, chromeColor: NSColor?, onEnd: @escaping () -> Void, ready: @escaping (ReloadHold?) -> Void) {
        webView.callAsyncJavaScript(noteAnchor, arguments: [:], in: nil, in: .defaultClient) { result in
            let anchor = (try? result.get()) as? [String: Any] ?? [:]
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            webView.takeSnapshot(with: configuration) { image, _ in
                ready(
                    image.map { ReloadHold(webView: webView, image: $0, anchor: anchor, chromeColor: chromeColor, onEnd: onEnd) })
            }
        }
    }

    private init(webView: WKWebView, image: NSImage, anchor: [String: Any], chromeColor: NSColor?, onEnd: @escaping () -> Void) {
        (self.webView, self.anchor, self.chromeColor, self.onEnd) = (webView, anchor, chromeColor, onEnd)
        cover = Cover(image: image)
        cover.frame = webView.bounds
        cover.autoresizingMask = [.width, .height]
        cover.onScroll = { [weak self] in self?.end() }
        webView.addSubview(cover)
        // Whatever happens to the load, the picture never outstays it by long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.end() }
    }

    /// The new page has committed: wait for it to settle, line it up with the anchor, then uncover.
    func pageCommitted() {
        webView?.callAsyncJavaScript(Self.settleAndAlign, arguments: ["anchor": anchor], in: nil, in: .defaultClient) { [weak self] _ in
            self?.end()
        }
    }

    /// Fades the picture out and releases the strip's color. Safe to call more than once.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        onEnd()
        let cover = cover
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            cover.animator().alphaValue = 0
        } completionHandler: {
            cover.removeFromSuperview()
        }
    }

    /// The still picture. It takes clicks, so none lands on a page the person cannot see, and a scroll
    /// ends the hold and goes on to the page.
    private final class Cover: NSImageView {
        var onScroll: (() -> Void)?

        init(image: NSImage) {
            super.init(frame: .zero)
            self.image = image
            imageScaling = .scaleAxesIndependently
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : self }
        override func mouseDown(with event: NSEvent) {}

        override func scrollWheel(with event: NSEvent) {
            onScroll?()
            super.scrollWheel(with: event)
        }
    }

    /// Finds an element near the top of the viewport that can be found again after the reload: one with
    /// an id, a link, or a leaf with some text. It must start inside the viewport and be shorter than it,
    /// or lining it up again would not correct a shift inside it. Returns {} at the top of the page.
    private static let noteAnchor = """
        if (scrollY <= 0) return {};
        const describe = element => {
            const box = element.getBoundingClientRect();
            if (box.top < 0 || box.top > innerHeight * 0.8 || box.height > innerHeight || box.height === 0) return null;
            const text = (element.textContent || '').trim().slice(0, 80);
            const base = { top: box.top, page: box.top + scrollY, tag: element.tagName };
            if (element.id) return { ...base, id: element.id };
            if (element.tagName === 'A' && element.getAttribute('href')) return { ...base, href: element.getAttribute('href'), text };
            if (element.children.length === 0 && text.length >= 12) return { ...base, text };
            return null;
        };
        for (const fy of [0.1, 0.25, 0.4, 0.6]) {
            for (const fx of [0.5, 0.35, 0.65, 0.2]) {
                for (let element = document.elementFromPoint(innerWidth * fx, innerHeight * fy); element && element !== document.body; element = element.parentElement) {
                    const found = describe(element);
                    if (found) return found;
                }
            }
        }
        return {};
        """

    /// Resolves once the page has settled and been lined up with `anchor`, and two frames have been drawn
    /// since. Settled means loaded, with no element added or removed, no change of height and no scroll
    /// for 300 ms; it gives up waiting after 2.5 s. Afterwards it keeps the anchor in place each frame for
    /// 2.5 s more, unless the person scrolls, clicks or types.
    private static let settleAndAlign = """
        const find = () => {
            if (anchor.id) return document.getElementById(anchor.id);
            const pool = anchor.href ? Array.from(document.links).filter(a => a.getAttribute('href') === anchor.href)
                : anchor.text ? Array.from(document.getElementsByTagName(anchor.tag)) : [];
            const matches = pool.filter(e => (e.textContent || '').trim().slice(0, 80) === anchor.text);
            const distance = e => Math.abs(e.getBoundingClientRect().top + scrollY - anchor.page);
            return matches.sort((p, q) => distance(p) - distance(q))[0] || null;
        };
        const align = () => {
            const element = anchor.top === undefined ? null : find();
            if (!element) return false;
            const delta = element.getBoundingClientRect().top - anchor.top;
            // Instant, because a page that asks for smooth scrolling would otherwise glide into place in view.
            if (Math.abs(delta) >= 0.5) scrollBy({ top: delta, behavior: 'instant' });
            return true;
        };
        return await new Promise(resolve => {
            const start = performance.now();
            let changed = start, loaded = document.readyState === 'complete', height = 0;
            const touch = () => { changed = performance.now(); };
            const observer = new MutationObserver(touch);
            observer.observe(document, { childList: true, subtree: true });
            addEventListener('scroll', touch, { passive: true, capture: true });
            addEventListener('load', () => { loaded = true; touch(); });
            const timer = setInterval(() => {
                if (document.documentElement.scrollHeight !== height) { height = document.documentElement.scrollHeight; touch(); }
                const now = performance.now();
                if (!(loaded && now - changed >= 300) && now - start < 2500) return;
                clearInterval(timer);
                observer.disconnect();
                removeEventListener('scroll', touch, { capture: true });
                let locked = align();
                const release = () => { locked = false; };
                for (const type of ['wheel', 'touchstart', 'mousedown', 'keydown']) addEventListener(type, release, { passive: true, capture: true, once: true });
                const until = performance.now() + 2500;
                // A change of size is reported after layout and before painting, so a shift that comes with
                // one is undone before it is ever drawn; the frame loop catches whatever else moves.
                const resized = new ResizeObserver(() => { if (locked && performance.now() < until) align(); });
                resized.observe(document.body);
                const hold = () => {
                    if (locked && performance.now() < until) { align(); requestAnimationFrame(hold); } else { resized.disconnect(); }
                };
                requestAnimationFrame(() => requestAnimationFrame(() => { resolve(true); hold(); }));
            }, 50);
        });
        """
}
