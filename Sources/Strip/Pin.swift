import AppKit

/// A pinned tab, shown as its site's icon, or the first letter of its site when it has none. Click
/// selects it; the context menu unpins it.
final class Pin: NSView, TabItem {
    private(set) weak var tab: Tab?
    var letter = "" { didSet { if letter != oldValue { label.stringValue = letter } } }
    /// The page's title, shown as the tooltip.
    var title = "" { didSet { if title != oldValue { toolTip = title } } }
    var icon: NSImage? {
        didSet {
            guard icon !== oldValue else { return }
            iconView.image = icon
            label.isHidden = icon != nil
        }
    }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    var onSelect: (() -> Void)?
    var onUnpin: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    init(tab: Tab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = StripMetrics.radius
        layer?.cornerCurve = .continuous
        label.font = StripMetrics.monogramFont
        label.alignment = .center
        iconView.contentTintColor = .textColor
        [label, iconView].forEach(addSubview)

        let menu = NSMenu()
        menu.addItem(withTitle: "Unpin Tab", action: #selector(unpinClicked), keyEquivalent: "").target = self
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.05).cgColor
        label.textColor = NSColor.textColor.withAlphaComponent(isActive ? 0.9 : 0.29)
        iconView.alphaValue = isActive ? 1 : 0.5
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 7, width: bounds.width, height: 16)
        iconView.frame = NSRect(x: (bounds.width - 16) / 2, y: 7, width: 16, height: 16)
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    @objc private func unpinClicked() { onUnpin?() }
}
