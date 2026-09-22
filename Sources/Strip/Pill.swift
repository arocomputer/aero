import AppKit

/// One ordinary tab in the strip. The strip draws the active tab's background; the pill itself shows the
/// site's icon when it has one, a hover tint, a close "×" on hover, and loading as a darker fill that
/// sweeps left to right with `progress`. Hovering crossfades the favicon to site information without
/// moving the title. Without an icon, the title slides aside. The close button keeps its reserved space.
final class Pill: NSView, TabItem {
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
    var isActive = false {
        didSet {
            if isActive != oldValue {
                needsDisplay = true
                arrangeTitle(animated: true)
            }
        }
    }
    var isLoading = false { didSet { if isLoading != oldValue { fill.animator().alphaValue = isLoading ? 1 : 0 } } }
    var progress: Double = 0 { didSet { if progress != oldValue { updateFill(animated: progress > oldValue) } } }
    /// Whether the context menu offers pinning; blank and ephemeral tabs cannot be pinned.
    var canPin = true
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)? { didSet { closeButton.onClick = onClose } }
    var onPin: (() -> Void)?
    var onSiteInformation: (() -> Void)?
    var onCopyLink: (() -> Void)?
    /// A press that moves far enough becomes a drag; the strip reorders the tab as `onDrag` reports
    /// the pointer, and `onDragEnd` finishes the gesture.
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var representsGroup = false { didSet { if representsGroup != oldValue { needsLayout = true } } }
    /// Where the pointer went down, to tell a click from a drag, and whether the press became one.
    private var pressOrigin: NSPoint?
    private var isDragging = false

    private let fill = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = StripButton(symbol: "xmark", pointSize: 11)
    private let infoButton = StripButton(symbol: "info.circle", pointSize: 13, weight: .regular)
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            arrangeTitle(animated: true)
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
        infoButton.alphaValue = 0
        infoButton.toolTip = "Site Information and Permissions"
        infoButton.setAccessibilityLabel("Site Information and Permissions")
        infoButton.onClick = { [weak self] in self?.onSiteInformation?() }
        [fill, iconView, label, infoButton, closeButton].forEach(addSubview)

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

    /// Only visible controls intercept a tab click; the title and favicon select the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === closeButton && isHovered { return hit }
        if hit === infoButton && showsInformation { return hit }
        return self
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textColor.withAlphaComponent(isHovered && !isActive ? 0.04 : 0).cgColor
        fill.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.07).cgColor
        label.textColor = isActive ? .textColor : NSColor.textColor.withAlphaComponent(0.57)
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 10, y: 7, width: 16, height: 16)
        closeButton.frame = NSRect(x: bounds.width - 27, y: 5, width: 20, height: 20)
        arrangeTitle(animated: false)
        updateFill(animated: false)
    }

    private var titleInset: CGFloat { icon == nil ? 12 : 33 }
    private var showsInformation: Bool {
        !representsGroup && isHovered && AddressInput.isWeb(tab?.url) && bounds.width >= (icon == nil ? titleInset + 70 : 58)
    }

    /// One interruptible transition swaps the leading icon in both directions. Only iconless tabs
    /// move their title; narrow tabs give the close button priority over the leading control.
    private func arrangeTitle(animated: Bool) {
        let shown = showsInformation
        let x = titleInset + (shown && icon == nil ? 22 : 0)
        let titleFrame = NSRect(x: x, y: 7, width: max(0, bounds.width - x - 28), height: 16)
        // Two points of padding around the existing glyph slot enlarge the hover disc and hit target.
        let infoFrame = NSRect(x: icon == nil ? titleInset - 2 + (shown ? 0 : -4) : 8, y: 5, width: 20, height: 20)
        let iconCovered = isHovered && closeButton.frame.minX < iconView.frame.maxX + 2
        infoButton.setAccessibilityHidden(!shown)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.16 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.animator().frame = titleFrame
            infoButton.animator().frame = infoFrame
            infoButton.animator().alphaValue = shown ? 1 : 0
            iconView.animator().alphaValue = shown || iconCovered ? 0 : isActive ? 1 : 0.6
            closeButton.animator().alphaValue = isHovered ? 1 : 0
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if !representsGroup && AddressInput.isWeb(tab?.url) {
            menu.addItem(withTitle: "Site Information…", action: #selector(informationClicked), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Link", action: #selector(copyLinkClicked), keyEquivalent: "").target = self
        }
        if canPin { menu.addItem(withTitle: "Pin Tab", action: #selector(pinClicked), keyEquivalent: "").target = self }
        menu.addItem(withTitle: representsGroup ? "Close Group" : "Close Tab", action: #selector(closeClicked), keyEquivalent: "").target =
            self
        return menu
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        isDragging = false
        onSelect?()
    }

    /// A collapsed group has no single tab to move, so it stays a click.
    override func mouseDragged(with event: NSEvent) {
        guard !representsGroup, let origin = pressOrigin else { return }
        if !isDragging {
            guard abs(event.locationInWindow.x - origin.x) > 3 || abs(event.locationInWindow.y - origin.y) > 3 else { return }
            isDragging = true
        }
        onDrag?(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
        guard isDragging else { return }
        isDragging = false
        onDragEnd?()
    }

    override func otherMouseDown(with event: NSEvent) { onClose?() }

    @objc private func pinClicked() { onPin?() }
    @objc private func informationClicked() { onSiteInformation?() }
    @objc private func copyLinkClicked() { onCopyLink?() }
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
