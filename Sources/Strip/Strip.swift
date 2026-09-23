import AppKit

/// The single strip of chrome, filling the window's titlebar: a hairline after the traffic lights, the
/// back, forward and reload controls, pinned tabs as site icons or monograms, then tab pills, then a "+" that
/// shows while the pointer is over the strip. Laid out by hand; empty areas drag the window, and a tab
/// dragged along it reorders, leaves for a window of its own, or joins another window's strip.
/// Changes to the tabs animate: the active highlight slides between items, new ones slide in, the rest make room.
/// It has no surface of its own: it shows the color along the page's top edge, and its `appearance`
/// is set light or dark to stay legible on it. See `setTint(_:fading:)`.
final class Strip: NSControl {
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
    /// The pill a drag holds under the pointer, which arranging leaves alone, and the slot it will
    /// settle into when let go.
    private weak var held: Pill?
    private var heldSlot = NSRect.zero
    /// What the last animated arrangement was made for; see `update`.
    private var arranged: Arrangement?
    private let highlight = Shade(opacity: 0.08, radius: StripMetrics.radius)
    private let separator = Shade(opacity: 0.14, radius: 0)
    // The two chevron symbols do not share a center: at 14pt their ink sits about 0.5pt left and 1pt
    // right of the button, so each is nudged back to the middle and the pair reads as one mirrored pair.
    private let backButton = StripButton(symbol: "chevron.backward", pointSize: 14, weight: .medium, offset: CGPoint(x: 0.5, y: 0))
    private let forwardButton = StripButton(symbol: "chevron.forward", pointSize: 14, weight: .medium, offset: CGPoint(x: -1, y: 0))
    private let reloadButton = StripButton(symbol: "arrow.clockwise", pointSize: 13, weight: .medium)
    private let plusButton = StripButton(symbol: "plus", pointSize: 13, discFillsButton: true)
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

        backButton.toolTip = "Back"
        backButton.setAccessibilityLabel("Back")
        backButton.onClick = { [weak self] in self?.controller?.goBackInHistory(nil) }
        forwardButton.toolTip = "Forward"
        forwardButton.setAccessibilityLabel("Forward")
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
    /// Keeps the window server from moving the window from anywhere in the strip. The server decides
    /// on its own, before the app sees a press, from a region AppKit only refreshes when the view tree
    /// changes shape; tabs slide and reorder without that, so per-tab exclusions went stale and a tab
    /// dragged the window. Only an enabled `NSControl` that refuses `mouseDownCanMoveWindow` counts,
    /// hence the superclass. The strip moves the window itself instead, from `mouseDown(with:)`; a
    /// subview that allows moving, such as a dimmed button, gets AppKit's in-app window drag.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Reached only on empty strip, as the title bar would be.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            (window as? Window)?.performTitlebarDoubleClick()
        } else {
            window?.performDrag(with: event)
        }
    }

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
            pill.onCopyLink = { [weak self, weak tab] in tab.map { self?.controller?.copyLink(of: $0) } }
            pill.onDrag = { [weak self, weak pill] origin in
                guard let self, let pill else { return }
                trackDrag(of: pill, grabbedAt: origin)
            }
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
            order: pins.map(ObjectIdentifier.init) + pills.map(ObjectIdentifier.init),
            leading: leadingInset, trailing: trailingInset, width: bounds.width, showsDownloads: showsDownloads)
        if arrangement != arranged || !entering.isEmpty {
            arranged = arrangement
            arrange(animated: bounds.width > 0)
        }
    }

    /// Follows a tab drag from the pill's first movement to the release, in an event loop of its own
    /// so the drag can leave this strip and this window. While the pointer stays on a strip the tab
    /// reorders there; once it leaves, the tab goes into a window that follows the pointer, held where
    /// it was grabbed, and dropping that window's tab over any other window's strip moves it in.
    /// `origin` is where the press began, in window coordinates.
    private func trackDrag(of pill: Pill, grabbedAt origin: NSPoint) {
        guard let tab = pill.tab else { return }
        let grabX = convert(origin, from: nil).x - pill.frame.minX
        var home: Strip? = self
        var loose: (window: NSWindow, handle: NSPoint)?
        while let event = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true),
            event.type == .leftMouseDragged
        {
            let mouse = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            if let strip = home {
                // The margin keeps a tab from tearing off as the pointer wobbles along the strip's edge.
                guard !strip.contains(mouse, margin: 24) else {
                    strip.slide(tab, to: mouse, grabbedAt: grabX)
                    continue
                }
                strip.letGo()
                guard let torn = strip.tearOff(tab, grabbedAt: grabX) else { continue }
                home = nil
                loose = torn
            }
            guard let (window, handle) = loose else { continue }
            if let target = Strip.dropTarget(at: mouse, excluding: window), target.attach(tab, at: mouse) {
                home = target
                loose = nil
            } else {
                window.setFrameOrigin(NSPoint(x: mouse.x - handle.x, y: mouse.y - handle.y))
            }
        }
        home?.letGo()
    }

    /// Whether a screen point lies on this strip, or within `margin` of it.
    private func contains(_ mouse: NSPoint, margin: CGFloat = 0) -> Bool {
        guard let window else { return false }
        return bounds.insetBy(dx: -margin, dy: -margin).contains(convert(window.convertPoint(fromScreen: mouse), from: nil))
    }

    /// Holds the tab's pill under the pointer, `grabX` into it, within the row of tabs, and moves the tab
    /// into a neighbor's slot as soon as the pill's center enters it, half a tab's travel, so the row
    /// answers the hand rather than waiting for the pointer to reach the next tab. `WindowController.move`
    /// keeps the tab inside the ordinary range and tells the extension runtime.
    private func slide(_ tab: Tab, to mouse: NSPoint, grabbedAt grabX: CGFloat) {
        guard let controller, let window, let from = pills.firstIndex(where: { $0.tab === tab }) else { return }
        let pill = pills[from]
        if held !== pill {
            letGo()
            held = pill
            heldSlot = pill.frame
            pill.layer?.zPosition = 1
        }
        let slots = pills.map { $0 === pill ? heldSlot : $0.frame }
        let x = convert(window.convertPoint(fromScreen: mouse), from: nil).x - grabX
        pill.frame.origin.x = min(max(x, slots[0].minX), slots[slots.count - 1].minX)
        if activeItem === pill { highlight.frame = pill.frame }

        var destination = from
        for (index, slot) in slots.enumerated() where index != from {
            if index < from, pill.frame.midX < slot.maxX { destination = index; break }
            if index > from, pill.frame.midX > slot.minX { destination = index }
        }
        guard destination != from, let target = pills[destination].tab,
            let insertion = controller.tabs.firstIndex(where: { $0 === target })
        else { return }
        controller.move(tab, to: insertion)
    }

    /// Releases the held pill into its slot.
    private func letGo() {
        guard let pill = held else { return }
        held = nil
        pill.layer?.zPosition = 0
        arrange(animated: true)
    }

    /// Gives the tab a window of its own to drag: this one when the tab is all it holds, otherwise a new
    /// one, returned with the point in it that should sit under the pointer, `grabX` into the tab. Only
    /// an ordinary public tab can change windows; a private or extension tab has nowhere to go.
    private func tearOff(_ tab: Tab, grabbedAt grabX: CGFloat) -> (window: NSWindow, handle: NSPoint)? {
        guard let controller, !controller.isPrivate, tab.recordsActivity, tab.owner === controller,
            let app = NSApp.delegate as? AppDelegate
        else { return nil }
        let torn =
            controller.tabs.count == 1 ? controller : app.openWindow(url: nil, restorePins: false, initialTabs: [tab], focused: true)
        guard let window = torn.window else { return nil }
        // Measured in the turn the window was shown, and moved before it draws, so it never appears elsewhere.
        torn.strip.layoutSubtreeIfNeeded()
        let pill = torn.strip.pills.first { $0.tab === tab }?.frame ?? .zero
        return (window, torn.strip.convert(NSPoint(x: pill.minX + min(grabX, pill.width), y: pill.midY), to: nil))
    }

    /// The strip of the frontmost browser window under a screen point, skipping the window being
    /// dragged. Another app's window or a panel in front hides the strips behind it.
    private static func dropTarget(at mouse: NSPoint, excluding dragged: NSWindow) -> Strip? {
        for window in NSApp.orderedWindows where window !== dragged && window.isVisible && window.frame.contains(mouse) {
            guard let strip = (window.windowController as? WindowController)?.strip, strip.contains(mouse) else { return nil }
            return strip
        }
        return nil
    }

    /// Takes a tab from another window in at the pointer, selects it and brings this window forward.
    /// A private window refuses it.
    private func attach(_ tab: Tab, at mouse: NSPoint) -> Bool {
        guard let controller, let window else { return false }
        let x = convert(window.convertPoint(fromScreen: mouse), from: nil).x
        let ordinary = controller.tabs.filter(\.recordsActivity)
        let next = pills.first { $0.frame.midX > x }?.tab
        let index = next.flatMap { next in ordinary.firstIndex { $0 === next } } ?? ordinary.count
        guard controller.transfer(tab, to: index) else { return false }
        controller.select(tab)
        window.makeKeyAndOrderFront(nil)
        return true
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
        if let held, let slot = targets.firstIndex(where: { $0.0 === held }) {
            heldSlot = targets.remove(at: slot).1
        }
        let highlightTarget = activeItem === held ? highlight.frame : targets.first { $0.0 === activeItem }?.1 ?? .zero

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
    /// The item views in display order, so a reorder counts as an arrangement change.
    let order: [ObjectIdentifier]
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
