import AppKit

/// A small round symbol button for the strip, used for closing a tab, the new-tab "+" and navigation
/// controls. It is a bare glyph; the gray disc shows only while the pointer is over the button
/// itself. Disabled, it dims and ignores the pointer.
final class StripButton: NSView {
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }

    private let icon: NSImageView
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight = .semibold, rotation: CGFloat = 0) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)!
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))!
        icon = NSImageView(image: image)
        super.init(frame: .zero)
        wantsLayer = true
        icon.frameCenterRotation = rotation
        addSubview(icon)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textColor.withAlphaComponent(isHovered && isEnabled ? 0.12 : 0).cgColor
        icon.contentTintColor = NSColor.textColor.withAlphaComponent(isEnabled ? 0.6 : 0.2)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        icon.frame = bounds
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Claims the click so it doesn't fall through to the pill underneath; the action fires on release.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
