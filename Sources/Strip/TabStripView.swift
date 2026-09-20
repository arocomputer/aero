import AppKit

/// The single strip of chrome, filling the window's titlebar: a hairline after the traffic lights, the
/// back, forward and reload controls, pinned tabs as site icons or monograms, then tab pills, then a "+" that
/// shows while the pointer is over the strip. Laid out by hand; empty areas drag the window.
/// Changes to the tabs animate: the active highlight slides between items, new ones slide in, the rest make room.
/// It has no surface of its own: it shows the color along the page's top edge, and its `appearance`
/// is set light or dark to stay legible on it. Where the page's header is a material, a tint over a
/// blur of what scrolls beneath, the strip is the same: the color is thinned and a blur of the page
/// running under the strip shows through, so text leaving the header keeps fading through the tabs
/// instead of being cut off by a lid. See `show(pageColor:opacity:over:)`.
final class TabStripView: NSView {
    weak var controller: BrowserWindowController?
    /// Space reserved on the left for the traffic lights.
    var leadingInset: CGFloat = 86 { didSet { if leadingInset != oldValue { needsLayout = true } } }
    /// Matches the right controls to the close button's distance from the opposite window edge.
    var trailingInset: CGFloat = 14 { didSet { if trailingInset != oldValue { needsLayout = true } } }

    /// The color along the page's top edge, shown behind the strip; nil shows the window through.
    /// Every change glides over a moment, so the strip reads as one surface easing between the page's
    /// colors instead of stepping through samples.
    private var pageColor: NSColor?
    private var pageOpacity: CGFloat = 1
    /// Never thin enough to leave the tabs' titles on raw moving text.
    private static let leastOpacity: CGFloat = 0.6

    private let blur = Backdrop()
    private let tint = Surface()

    private var pinButtons: [PinButton] = []
    private var pills: [TabPillView] = []
    private var entering: [NSView] = []
    private var activeItem: NSView?
    /// What the last animated arrangement was made for; see `update`.
    private var arranged: Arrangement?
    private let highlight = TintView(opacity: 0.08, radius: Metrics.radius)
    private let separator = TintView(opacity: 0.14, radius: 0)
    private let backButton = StripButton(symbol: "chevron.backward", pointSize: 14, weight: .medium)
    private let forwardButton = StripButton(symbol: "chevron.forward", pointSize: 14, weight: .medium)
    private let reloadButton = StripButton(symbol: "arrow.clockwise", pointSize: 13, weight: .medium)
    private let plusButton = StripButton(symbol: "plus", pointSize: 13)
    private let downloadsButton = StripButton(symbol: "arrow.down.circle", pointSize: 14, weight: .medium)
    private let menuButton = StripButton(symbol: "ellipsis", pointSize: 15, weight: .bold)
    var showsDownloads = false {
        didSet {
            guard showsDownloads != oldValue else { return }
            downloadsButton.isHidden = !showsDownloads
            if showsDownloads {
                downloadsButton.alphaValue = 0
                downloadsButton.animator().alphaValue = 1
            }
            needsLayout = true
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blur.blendingMode = .withinWindow
        blur.material = .headerView
        blur.state = .active
        blur.isHidden = true
        for surface in [blur, tint] as [NSView] {
            surface.frame = bounds
            surface.autoresizingMask = [.width, .height]
            addSubview(surface)
        }
        addSubview(highlight)

        backButton.onClick = { [weak self] in self?.controller?.goBackInHistory(nil) }
        forwardButton.onClick = { [weak self] in self?.controller?.goForwardInHistory(nil) }
        reloadButton.toolTip = "Reload"
        reloadButton.onClick = { [weak self] in self?.controller?.reloadPage(nil) }
        [separator, backButton, forwardButton, reloadButton].forEach(addSubview)
        plusButton.onClick = { [weak self] in self?.controller?.newTab(nil) }
        plusButton.alphaValue = 0
        addSubview(plusButton)
        downloadsButton.toolTip = "Downloads"
        downloadsButton.onClick = { [weak self] in
            guard let self else { return }
            controller?.showDownloads(relativeTo: downloadsButton)
        }
        downloadsButton.isHidden = true
        addSubview(downloadsButton)
        menuButton.toolTip = "\(appName) Menu"
        menuButton.onClick = { [weak self] in
            guard let self else { return }
            controller?.toggleBrowserMenu(relativeTo: menuButton)
        }
        addSubview(menuButton)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Allows the system's title-bar double-click only when no tab or control occupies the point.
    func allowsWindowZoom(at pointInWindow: NSPoint) -> Bool {
        let point = convert(pointInWindow, from: nil)
        return bounds.contains(point) && hitTest(point) === self
    }

    /// Shows the color along the page's top edge, `opacity` of it over a blur of the page when that is
    /// below 1; nil shows the window through. `glide` is how long the page's own header takes to get
    /// there: the strip fades over the same time with the same easing, so the two change as one. A
    /// change the page makes at once is shown at once, softened only enough not to flash.
    func show(pageColor color: NSColor?, opacity: CGFloat, over glide: TimeInterval) {
        guard color != pageColor || opacity != pageOpacity else { return }
        (pageColor, pageOpacity) = (color, opacity)
        let shown = max(opacity, Self.leastOpacity)
        blur.isHidden = color == nil || shown >= 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = glide > 0 ? min(glide, 1) : 0.05
            // The default curve is CSS's `ease`, which is what nearly every header fades with.
            context.timingFunction = CAMediaTimingFunction(name: glide > 0 ? .default : .linear)
            context.allowsImplicitAnimation = true
            tint.layer?.backgroundColor = color?.withAlphaComponent(shown).cgColor
        }
    }

    /// Brings pinned items and pills in line with the controller's tabs (pinned ones first), animating
    /// what moved. This runs on every title and progress tick of every tab, so it only compares: each
    /// view is made once for its tab, its setters do nothing for a value they already show, and frames
    /// are touched only when the arrangement changed.
    func update(tabs: [Tab], active: Tab?) {
        var pinned: [Tab] = [], ordinary: [Tab] = []
        for tab in tabs { if tab.isPinned { pinned.append(tab) } else { ordinary.append(tab) } }
        pinButtons = matched(pinButtons, to: pinned) { [weak self] tab in
            let button = PinButton(tab: tab)
            button.onSelect = { [weak self, weak tab] in tab.map { self?.controller?.select($0) } }
            button.onUnpin = { [weak self, weak tab] in tab.map { self?.controller?.setPinned(false, tab: $0) } }
            return button
        }
        pills = matched(pills, to: ordinary) { [weak self] tab in
            let pill = TabPillView(tab: tab)
            pill.onSelect = { [weak self, weak tab] in tab.map { self?.controller?.select($0) } }
            pill.onClose = { [weak self, weak tab] in tab.map { self?.controller?.close($0) } }
            pill.onPin = { [weak self, weak tab] in tab.map { self?.controller?.setPinned(true, tab: $0) } }
            return pill
        }
        activeItem = nil
        backButton.isEnabled = active?.webView.canGoBack ?? false
        forwardButton.isEnabled = active?.webView.canGoForward ?? false
        reloadButton.isEnabled = active?.isBlank == false

        for (button, tab) in zip(pinButtons, pinned) {
            button.letter = tab.monogram
            button.icon = tab.favicon
            button.title = tab.title
            button.isActive = tab === active
            if tab === active { activeItem = button }
        }
        for (pill, tab) in zip(pills, ordinary) {
            pill.title = tab.title
            pill.icon = tab.favicon
            pill.isActive = tab === active
            pill.progress = tab.webView.estimatedProgress
            pill.isLoading = tab.webView.isLoading
            pill.canPin = !tab.isBlank
            if tab === active { activeItem = pill }
        }
        let arrangement = Arrangement(
            pins: pinButtons.count, pills: pills.count, active: activeItem.map(ObjectIdentifier.init),
            leading: leadingInset, trailing: trailingInset, width: bounds.width, showsDownloads: showsDownloads)
        if arrangement != arranged || !entering.isEmpty {
            arranged = arrangement
            arrange(animated: bounds.width > 0)
        }
    }

    /// Brings a list of item views in line with `tabs`. A view stays with its tab for life, so a closed
    /// tab takes its own view with it and the others slide over, instead of the last view going and
    /// every title shifting down one.
    private func matched<Item: TabItem>(_ items: [Item], to tabs: [Tab], make: (Tab) -> Item) -> [Item] {
        if items.count == tabs.count, zip(items, tabs).allSatisfy({ $0.tab === $1 }) { return items }
        var left = items
        let matched = tabs.map { tab -> Item in
            if let index = left.firstIndex(where: { $0.tab === tab }) { return left.remove(at: index) }
            let item = make(tab)
            entering.append(item)
            addSubview(item)
            return item
        }
        left.forEach { $0.removeFromSuperview() }
        return matched
    }

    override func layout() {
        super.layout()
        arrange(animated: false)
    }

    /// Positions everything. Frames that are already right are left alone, so a plain layout pass
    /// never cuts an animation short.
    private func arrange(animated: Bool) {
        var targets: [(NSView, NSRect)] = []
        let y = (bounds.height - Metrics.itemHeight) / 2 - Metrics.topLift
        // The hairline sits between the traffic lights and the arrows; in full screen there are no lights.
        separator.isHidden = leadingInset < 40
        separator.frame = NSRect(x: leadingInset - 6, y: (bounds.height - 16) / 2 - Metrics.topLift, width: 1, height: 16)
        var x = separator.isHidden ? leadingInset : leadingInset + 5
        for control in [backButton, forwardButton, reloadButton] {
            control.frame = NSRect(
                x: x, y: (bounds.height - Metrics.arrowSize) / 2 - Metrics.topLift,
                width: Metrics.arrowSize, height: Metrics.arrowSize)
            x += Metrics.arrowSize + 2
        }
        x += 8
        for button in pinButtons {
            targets.append((button, NSRect(x: x, y: y, width: Metrics.pinWidth, height: Metrics.itemHeight)))
            x += Metrics.pinWidth + Metrics.gap
        }
        if !pinButtons.isEmpty { x += 4 }

        var trailingStart = bounds.width - trailingInset - Metrics.itemHeight
        if showsDownloads { trailingStart -= Metrics.itemHeight + 4 }
        let available = trailingStart - x - 48
        let width = min(Metrics.pillWidth, max(44, available / CGFloat(max(pills.count, 1)) - Metrics.gap)).rounded(.down)
        for pill in pills {
            targets.append((pill, NSRect(x: x, y: y, width: width, height: Metrics.itemHeight)))
            x += width + Metrics.gap
        }
        targets.append((plusButton, NSRect(x: x + 2, y: y, width: Metrics.itemHeight, height: Metrics.itemHeight)))
        var trailingX = bounds.width - trailingInset
        trailingX -= Metrics.itemHeight
        targets.append((menuButton, NSRect(x: trailingX, y: y, width: Metrics.itemHeight, height: Metrics.itemHeight)))
        if showsDownloads {
            trailingX -= Metrics.itemHeight + 4
            targets.append((downloadsButton, NSRect(x: trailingX, y: y, width: Metrics.itemHeight, height: Metrics.itemHeight)))
        }
        let highlightTarget = targets.first { $0.0 === activeItem }?.1 ?? .zero

        guard animated else {
            for (view, frame) in targets + [(highlight, highlightTarget)] where view.frame != frame { view.frame = frame }
            entering = []
            return
        }

        for view in entering {
            guard let target = targets.first(where: { $0.0 === view })?.1 else { continue }
            view.frame = target.offsetBy(dx: -18, dy: 0)
            view.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            for (view, frame) in targets where view.frame != frame { view.animator().frame = frame }
            entering.forEach { $0.animator().alphaValue = 1 }
        }
        // The highlight overshoots slightly and settles, which reads as a light spring.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.35, 0.5, 1)
            if highlight.frame.isEmpty { highlight.frame = highlightTarget } else { highlight.animator().frame = highlightTarget }
        }
        entering = []
    }

    override func mouseEntered(with event: NSEvent) { plusButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { plusButton.animator().alphaValue = 0 }
}

/// The strip's color. It and the blur behind it are passed over by the pointer, so clicks on empty
/// strip still reach the strip, which drags and zooms the window.
private final class Surface: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class Backdrop: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Everything that moves the strip's items: how many there are, which is active and the space they get.
private struct Arrangement: Equatable {
    let pins: Int, pills: Int
    let active: ObjectIdentifier?
    let leading: CGFloat, trailing: CGFloat, width: CGFloat
    let showsDownloads: Bool
}

/// A strip item that shows one tab for as long as it lives.
private protocol TabItem: NSView {
    var tab: Tab? { get }
}

/// A flat tint of the strip's text color that follows the strip's light or dark appearance: the active
/// tab's background, which slides between items, and the hairline after the traffic lights.
private final class TintView: NSView {
    private let opacity: CGFloat

    init(opacity: CGFloat, radius: CGFloat) {
        self.opacity = opacity
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textColor.withAlphaComponent(opacity).cgColor
    }
}

/// Sizes of the strip's items. The proportions come from the reference design, scaled up to sit in the
/// system's regular 52pt toolbar instead of its 44pt one.
private enum Metrics {
    static let topLift: CGFloat = 6
    static let itemHeight: CGFloat = 30
    static let pillWidth: CGFloat = 208
    static let pinWidth: CGFloat = 32
    static let arrowSize: CGFloat = 28
    static let gap: CGFloat = 3
    static let radius: CGFloat = 10
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let monogramFont = NSFont.systemFont(ofSize: 13, weight: .medium)
}

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
        layer?.cornerRadius = Metrics.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        fill.wantsLayer = true
        fill.alphaValue = 0
        iconView.contentTintColor = .textColor
        label.font = Metrics.titleFont
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

/// A pinned tab, shown as its site's icon, or the first letter of its site when it has none. Click
/// selects it; the context menu unpins it.
final class PinButton: NSView, TabItem {
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
        layer?.cornerRadius = Metrics.radius
        layer?.cornerCurve = .continuous
        label.font = Metrics.monogramFont
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
