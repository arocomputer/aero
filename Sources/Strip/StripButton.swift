import AppKit

/// A small round symbol button for the strip, used for closing a tab, the new-tab "+" and navigation
/// controls. The gray disc hugs the glyph and is centered on it; it shows only while the pointer is
/// over the button itself. The new-tab "+" fills its button instead, a disc as tall as a tab.
/// Disabled, the button dims and hands the press back to the title bar, so a greyed control drags the
/// window.
final class StripButton: NSView {
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }

    private let disc = NSView()
    private let icon: NSImageView
    /// Nudges the glyph in points, for symbols whose ink does not sit at the image's center.
    private let offset: CGPoint
    /// Whether the hover disc fills the button rather than hugging the glyph. The new-tab "+" asks for
    /// this, so its highlight stands a whole tab high and its rim reaches the tabs' top and bottom edges.
    private let discFillsButton: Bool
    private var isHovered = false { didSet { needsDisplay = true } }

    init(
        symbol: String, pointSize: CGFloat, weight: NSFont.Weight = .semibold, rotation: CGFloat = 0, offset: CGPoint = .zero,
        discFillsButton: Bool = false
    ) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)!
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))!
        icon = NSImageView(image: image)
        self.offset = offset
        self.discFillsButton = discFillsButton
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        icon.frameCenterRotation = rotation
        disc.wantsLayer = true
        disc.layer?.cornerCurve = .continuous
        addSubview(disc)
        addSubview(icon)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A control that is not doing anything is title background: a greyed control lets the title bar
    /// drag, while an apparent one keeps the press. The menu button is never disabled, so it never drags.
    override var mouseDownCanMoveWindow: Bool { !isEnabled }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    /// Sizes the disc to the glyph with even padding, and centers both, so the highlight can never read
    /// as a loose or off-center pad behind the icon. A button that asks for it fills instead, a disc as
    /// tall as the button, matching the tabs' height.
    override func layout() {
        super.layout()
        let glyph = icon.image?.size ?? .zero
        let diameter =
            discFillsButton
            ? min(bounds.width, bounds.height)
            : min(bounds.width, bounds.height, max(glyph.width, glyph.height) + 7)
        disc.frame = NSRect(
            x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        disc.layer?.cornerRadius = diameter / 2
        icon.frame = bounds.offsetBy(dx: offset.x, dy: offset.y)
    }

    override func updateLayer() {
        disc.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(isHovered && isEnabled ? 0.12 : 0).cgColor
        icon.contentTintColor = NSColor.textColor.withAlphaComponent(isEnabled ? 0.6 : 0.2)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Claims the click so it doesn't fall through to the pill underneath; the action fires on release.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }
}
