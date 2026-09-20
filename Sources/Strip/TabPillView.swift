import AppKit

/// One ordinary tab in the strip. The strip draws the active tab's background; the pill itself shows the
/// site's icon when it has one, a hover tint, a close "×" on hover, and loading as a darker fill that
/// sweeps left to right with `progress`. The title always leaves room for the close button, so hovering
/// never reflows it.
final class TabPillView: NSView, TabItem {
    private(set) weak var tab: Tab?
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            label.stringValue = title
            toolTip = title
        }
    }
    /// The site's icon, shown before the title; without one the title starts at the pill's edge.
    var icon: NSImage? {
        didSet {
            guard icon !== oldValue else { return }
            iconView.image = icon
            needsLayout = true
        }
    }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    var isLoading = false { didSet { if isLoading != oldValue { fill.animator().alphaValue = isLoading ? 1 : 0 } } }
    var progress: Double = 0 { didSet { if progress != oldValue { updateFill(animated: progress > oldValue) } } }
    /// Whether the context menu offers pinning; a blank tab has nothing to pin.
    var canPin = true
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)? { didSet { closeButton.onClick = onClose } }
    var onPin: (() -> Void)?

    private let fill = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = StripButton(symbol: "xmark", pointSize: 11)
    private var isHovered = false {
        didSet {
            needsDisplay = true
            closeButton.animator().alphaValue = isHovered ? 1 : 0
        }
    }

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = StripMetrics.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        fill.wantsLayer = true
        fill.alphaValue = 0
        iconView.contentTintColor = .textColor
        label.font = StripMetrics.titleFont
        label.lineBreakMode = .byTruncatingTail
        closeButton.alphaValue = 0
        [fill, iconView, label, closeButton].forEach(addSubview)

        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Everything but the close button counts as the pill, so the title can't swallow clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton && isHovered ? hit : self
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textColor.withAlphaComponent(isHovered && !isActive ? 0.04 : 0).cgColor
        fill.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.07).cgColor
        label.textColor = isActive ? .textColor : NSColor.textColor.withAlphaComponent(0.57)
        // In a pill too narrow for both, the icon gives way to the close button.
        let isCovered = isHovered && closeButton.frame.minX < iconView.frame.maxX + 2
        iconView.alphaValue = isCovered ? 0 : isActive ? 1 : 0.6
    }

    override func layout() {
        super.layout()
        let titleX: CGFloat = icon == nil ? 12 : 33
        iconView.frame = NSRect(x: 10, y: 7, width: 16, height: 16)
        label.frame = NSRect(x: titleX, y: 7, width: max(0, bounds.width - titleX - 28), height: 16)
        closeButton.frame = NSRect(x: bounds.width - 25, y: 7, width: 16, height: 16)
        updateFill(animated: false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if canPin { menu.addItem(withTitle: "Pin Tab", action: #selector(pinClicked), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "Close Tab", action: #selector(closeClicked), keyEquivalent: "").target = self
        return menu
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func otherMouseDown(with event: NSEvent) { onClose?() }

    @objc private func pinClicked() { onPin?() }
    @objc private func closeClicked() { onClose?() }

    private func updateFill(animated: Bool) {
        let frame = NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        if animated {
            fill.animator().frame = frame
        } else {
            fill.frame = frame
        }
    }
}
