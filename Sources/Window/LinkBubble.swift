import AppKit

/// Shows where the link under the pointer leads, in a small card at the bottom of the page, drawn like
/// the address field so the two read as one family. It covers the content area but is never in the
/// way: the pointer passes through it, and when the pointer is where the card would sit, at the
/// bottom left, the card moves to the bottom right.
///
/// Motion follows the window's rule: it fades in and out briefly, and its text is never animated.
/// Leaving a link waits a moment before fading, so moving along a row of links does not blink.
final class LinkBubble: NSView {
    private let card = CardView()
    private let label = NSTextField(labelWithString: "")
    private var hiding: DispatchWorkItem?

    private enum Metrics {
        static let height: CGFloat = 26
        static let margin: CGFloat = 10
        static let padding: CGFloat = 11
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        // The middle gives way, so the site and the end of the path both stay readable.
        label.lineBreakMode = .byTruncatingMiddle
        card.layer?.cornerRadius = Metrics.height / 2
        card.alphaValue = 0
        card.addSubview(label)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `address`, or fades away when it is nil.
    func show(_ address: String?) {
        hiding?.cancel()
        guard let address else {
            let work = DispatchWorkItem { [weak self] in self?.fade(to: 0, over: 0.15) }
            hiding = work
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        label.stringValue = address
        place()
        fade(to: 1, over: 0.1)
    }

    /// Hides at once, for when the page under the pointer is no longer the one that was reported on.
    func dismiss() {
        hiding?.cancel()
        card.alphaValue = 0
    }

    override func layout() {
        super.layout()
        if card.alphaValue > 0 { place() }
    }

    private func place() {
        let widest = max(120, min(bounds.width * 0.6, 640))
        // A text field draws inside insets its measured width leaves out; without the allowance an
        // address that fits is cut in the middle anyway.
        let width = min(ceil(label.intrinsicContentSize.width) + 6 + Metrics.padding * 2, widest)
        let y = bounds.height - Metrics.height - Metrics.margin
        var frame = NSRect(x: Metrics.margin, y: y, width: width, height: Metrics.height)
        if let window, frame.insetBy(dx: -12, dy: -12).contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            frame.origin.x = bounds.width - width - Metrics.margin
        }
        card.frame = frame
        label.frame = NSRect(x: Metrics.padding, y: 5, width: width - Metrics.padding * 2, height: 16)
    }

    private func fade(to alpha: CGFloat, over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            card.animator().alphaValue = alpha
        }
    }
}
