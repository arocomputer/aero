import AppKit

/// The single strip of chrome, filling the window's titlebar: a hairline after the traffic lights, the
/// back, forward and reload controls, pinned tabs as site icons or monograms, then tab pills, then a "+" that
/// shows while the pointer is over the strip. Laid out by hand; empty areas drag the window.
/// Changes to the tabs animate: the active highlight slides between items, new ones slide in, the rest make room.
/// It has no surface of its own: it shows the color along the page's top edge, and its `appearance`
/// is set light or dark to stay legible on it. See `setTint(_:fading:)`.
final class Strip: NSView {
    weak var controller: WindowController?
    /// Space reserved on the left for the traffic lights.
    var leadingInset: CGFloat = 86 { didSet { if leadingInset != oldValue { needsLayout = true } } }
    /// Matches the right controls to the close button's distance from the opposite window edge.
    var trailingInset: CGFloat = 14 { didSet { if trailingInset != oldValue { needsLayout = true } } }

    /// The color along the page's top edge, shown behind the strip; see `setTint(_:fading:)`.
    private var tint: NSColor?

    private var pins: [Pin] = []
    private var pills: [Pill] = []
    private var entering: [NSView] = []
    private var activeItem: NSView?
    /// What the last animated arrangement was made for; see `update`.
    private var arranged: Arrangement?
    private let highlight = Shade(opacity: 0.08, radius: StripMetrics.radius)
    private let separator = Shade(opacity: 0.14, radius: 0)
    private let backButton = StripButton(symbol: "chevron.backward", pointSize: 14, weight: .medium)
    private let forwardButton = StripButton(symbol: "chevron.forward", pointSize: 14, weight: .medium)
    private let reloadButton = StripButton(symbol: "arrow.clockwise", pointSize: 13, weight: .medium)
    private let plusButton = StripButton(symbol: "plus", pointSize: 13)
    private let downloadsButton = StripButton(symbol: "arrow.down.circle", pointSize: 14, weight: .medium)
    private let menuButton = StripButton(symbol: "ellipsis", pointSize: 15, weight: .bold)
    private let privateLabel = NSTextField(labelWithString: "Private")
    private let groupIcon = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Tab group")
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
        addSubview(highlight)

        backButton.onClick = { [weak self] in self?.controller?.goBackInHistory(nil) }
        forwardButton.onClick = { [weak self] in self?.controller?.goForwardInHistory(nil) }
        reloadButton.toolTip = "Reload"
        reloadButton.onClick = { [weak self] in self?.controller?.reloadPage(nil) }
        privateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        privateLabel.textColor = .secondaryLabelColor
        privateLabel.toolTip =
            "Private browsing. Closing this window discards website storage and stops unfinished downloads. Completed files remain."
        privateLabel.isHidden = true
        [separator, backButton, forwardButton, reloadButton, privateLabel].forEach(addSubview)
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
            controller?.toggleMenuPanel(relativeTo: menuButton)
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

    /// Shows the color along the page's top edge; nil shows the window through. When the page's own
    /// header is fading there, `fading` is that fade, and the strip runs the same one: same length,
    /// same curve, started as the header starts, so the two change as one. A change the page makes at
    /// once is shown at once, with nothing added: the report leaves the page before the frame it
    /// describes does, so setting the color here puts both on the same refresh, and any softening
    /// would be lag.
    func setTint(_ color: NSColor?, fading: PageTint.Fade?) {
        guard color != tint else { return }
        tint = color
        guard let fading else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // A fade still running would carry on toward the new color at its own pace.
            layer?.removeAnimation(forKey: "backgroundColor")
            layer?.backgroundColor = color?.cgColor
            CATransaction.commit()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = min(fading.duration, 1)
            context.timingFunction = fading.curve
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = color?.cgColor
        }
    }

    /// Brings pinned items and pills in line with the controller's tabs (pinned ones first), animating
    /// what moved. This runs on every title and progress tick of every tab, so it only compares: each
    /// visible views are reused, their setters ignore unchanged values, and frames change only when
    /// the arrangement changes. Collapsed groups expose one representative item.
    func update(tabs: [Tab], active: Tab?) {
        var pinned: [Tab] = [], ordinary: [Tab] = []
        var groupCounts: [String: Int] = [:]
        for tab in tabs {
            if tab.isPinned { pinned.append(tab) } else { ordinary.append(tab) }
            if let group = tab.groupName { groupCounts[group, default: 0] += 1 }
        }
        let collapsed = controller?.collapsedGroups ?? []
        var seen: Set<String> = []
        ordinary = ordinary.compactMap { tab in
            guard let group = tab.groupName, collapsed.contains(group) else { return tab }
            guard seen.insert(group).inserted else { return nil }
            return active?.groupName == group ? active : tab
        }
        pins = matched(pins, to: pinned) { [weak self] tab in
            let button = Pin(tab: tab)
            button.onSelect = { [weak self, weak tab] in tab.map { self?.controller?.select($0) } }
            button.onUnpin = { [weak self, weak tab] in tab.map { self?.controller?.setPinned(false, tab: $0) } }
            button.onSiteInformation = { [weak self, weak tab, weak button] in
                guard let tab, let button else { return }
                self?.controller?.showSiteInformation(for: tab, relativeTo: button)
            }
            return button
        }
        pills = matched(pills, to: ordinary) { [weak self] tab in
            let pill = Pill(tab: tab)
            pill.onSelect = { [weak self, weak tab] in
                guard let tab, let controller = self?.controller else { return }
                if let group = tab.groupName, controller.collapsedGroups.contains(group) {
                    controller.toggleGroup(group)
                } else {
                    controller.select(tab)
                }
            }
            pill.onClose = { [weak self, weak tab] in
                guard let tab, let controller = self?.controller else { return }
                if let group = tab.groupName, controller.collapsedGroups.contains(group) {
                    controller.closeGroup(named: group)
                } else {
                    controller.close(tab)
                }
            }
            pill.onPin = { [weak self, weak tab] in tab.map { self?.controller?.setPinned(true, tab: $0) } }
            pill.onSiteInformation = { [weak self, weak tab, weak pill] in
                guard let tab, let pill else { return }
                self?.controller?.showSiteInformation(for: tab, relativeTo: pill)
            }
            return pill
        }
        activeItem = nil
        backButton.isEnabled = active?.webView.canGoBack ?? false
        forwardButton.isEnabled = active?.webView.canGoForward ?? false
        reloadButton.isEnabled = active?.isBlank == false

        for (button, tab) in zip(pins, pinned) {
            button.letter = tab.monogram
            button.icon = tab.favicon
            button.title = tab.title
            button.isActive = tab === active
            if tab === active { activeItem = button }
        }
        for (pill, tab) in zip(pills, ordinary) {
            pill.representsGroup = tab.groupName.map { collapsed.contains($0) } ?? false
            pill.title =
                tab.groupName.map { group in
                    pill.representsGroup ? "\(group) · \(groupCounts[group] ?? 0) tabs" : "\(group) · \(tab.title)"
                } ?? tab.title
            pill.icon = pill.representsGroup ? groupIcon : tab.favicon
            pill.isActive = tab === active
            pill.progress = tab.webView.estimatedProgress
            pill.isLoading = tab.webView.isLoading
            pill.canPin = !pill.representsGroup && !tab.isBlank && tab.recordsActivity
            if tab === active { activeItem = pill }
        }
        let arrangement = Arrangement(
            pins: pins.count, pills: pills.count, active: activeItem.map(ObjectIdentifier.init),
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
        let y = (bounds.height - StripMetrics.itemHeight) / 2 - StripMetrics.topLift
        // The hairline sits between the traffic lights and the arrows; in full screen there are no lights.
        separator.isHidden = leadingInset < 40
        separator.frame = NSRect(x: leadingInset - 6, y: (bounds.height - 16) / 2 - StripMetrics.topLift, width: 1, height: 16)
        var x = separator.isHidden ? leadingInset : leadingInset + 5
        for control in [backButton, forwardButton, reloadButton] {
            control.frame = NSRect(
                x: x, y: (bounds.height - StripMetrics.arrowSize) / 2 - StripMetrics.topLift,
                width: StripMetrics.arrowSize, height: StripMetrics.arrowSize)
            x += StripMetrics.arrowSize + 2
        }
        privateLabel.isHidden = controller?.isPrivate != true
        if !privateLabel.isHidden {
            privateLabel.frame = NSRect(x: x + 4, y: y + 8, width: 48, height: 16)
            x += 56
        }
        x += 8
        for button in pins {
            targets.append((button, NSRect(x: x, y: y, width: StripMetrics.pinWidth, height: StripMetrics.itemHeight)))
            x += StripMetrics.pinWidth + StripMetrics.gap
        }
        if !pins.isEmpty { x += 4 }

        var trailingStart = bounds.width - trailingInset - StripMetrics.itemHeight
        if showsDownloads { trailingStart -= StripMetrics.itemHeight + 4 }
        let available = trailingStart - x - 48
        let width = min(StripMetrics.pillWidth, max(44, available / CGFloat(max(pills.count, 1)) - StripMetrics.gap)).rounded(.down)
        for pill in pills {
            targets.append((pill, NSRect(x: x, y: y, width: width, height: StripMetrics.itemHeight)))
            x += width + StripMetrics.gap
        }
        targets.append((plusButton, NSRect(x: x + 2, y: y, width: StripMetrics.itemHeight, height: StripMetrics.itemHeight)))
        var trailingX = bounds.width - trailingInset
        trailingX -= StripMetrics.itemHeight
        targets.append((menuButton, NSRect(x: trailingX, y: y, width: StripMetrics.itemHeight, height: StripMetrics.itemHeight)))
        if showsDownloads {
            trailingX -= StripMetrics.itemHeight + 4
            targets.append((downloadsButton, NSRect(x: trailingX, y: y, width: StripMetrics.itemHeight, height: StripMetrics.itemHeight)))
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

/// Everything that moves the strip's items: how many there are, which is active and the space they get.
private struct Arrangement: Equatable {
    let pins: Int, pills: Int
    let active: ObjectIdentifier?
    let leading: CGFloat, trailing: CGFloat, width: CGFloat
    let showsDownloads: Bool
}

/// A strip item that shows one tab for as long as it lives.
protocol TabItem: NSView {
    var tab: Tab? { get }
}

/// A flat tint of the strip's text color that follows the strip's light or dark appearance: the active
/// tab's background, which slides between items, and the hairline after the traffic lights.
private final class Shade: NSView {
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
