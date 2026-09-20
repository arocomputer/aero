import AppKit

/// The state needed to label and enable the browser menu for the active tab.
struct MenuState {
    let isLoading: Bool
    let hasPage: Bool
    let canPin: Bool
    let isPinned: Bool
    let zoom: CGFloat
    let isFullScreen: Bool
}

/// Commands exposed by the browser menu. Zoom commands keep the menu open; the rest dismiss it.
enum MenuAction {
    case newTab
    case newWindow
    case openLocation
    case find
    case reloadOrStop
    case togglePin
    case copyLink
    case share
    case extensions
    case settings
    case zoomOut
    case resetZoom
    case zoomIn
    case print
    case toggleFullScreen
}

/// A rounded browser menu drawn inside the window so it matches the omnibox cards exactly.
final class MenuPanel: NSView {
    var onAction: ((MenuAction) -> Void)?
    var trailingInset: CGFloat = 14 { didSet { if trailingInset != oldValue { needsLayout = true } } }

    private let card = CardView()
    private let scroll = NSScrollView()
    private let content = MenuContent()
    private let newTab = MenuRow(symbol: "plus", title: "New Tab", shortcut: "⌘T")
    private let newWindow = MenuRow(symbol: "macwindow.badge.plus", title: "New Window", shortcut: "⌘N")
    private let openLocation = MenuRow(symbol: "magnifyingglass", title: "Open Location", shortcut: "⌘L")
    private let find = MenuRow(symbol: "text.magnifyingglass", title: "Find on Page", shortcut: "⌘F")
    private let reload = MenuRow(symbol: "arrow.clockwise", title: "Reload", shortcut: "⌘R")
    private let pin = MenuRow(symbol: "pin", title: "Pin Tab", shortcut: "⌘D")
    private let copyLink = MenuRow(symbol: "link", title: "Copy Page Link", shortcut: "")
    private let share = MenuRow(symbol: "square.and.arrow.up", title: "Share Page", shortcut: "")
    private let extensions = MenuRow(symbol: "square.grid.2x2", title: "Extensions", shortcut: "")
    private let settings = MenuRow(symbol: "gearshape", title: "Settings", shortcut: "⌘,")
    private let zoom = MenuZoomRow()
    private let printPage = MenuRow(symbol: "printer", title: "Print", shortcut: "⌘P")
    private let fullScreen = MenuRow(symbol: "arrow.up.left.and.arrow.down.right", title: "Enter Full Screen", shortcut: "⌃⌘F")
    private let separators = [MenuSeparator(), MenuSeparator(), MenuSeparator(), MenuSeparator()]

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        wantsLayer = true
        addSubview(card)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.documentView = content
        card.addSubview(scroll)

        let rows = [newTab, newWindow, openLocation, find, reload, pin, copyLink, share, extensions, settings, printPage, fullScreen]
        rows.forEach(content.addSubview)
        separators.forEach(content.addSubview)
        content.addSubview(zoom)

        newTab.onClick = { [weak self] in self?.choose(.newTab) }
        newWindow.onClick = { [weak self] in self?.choose(.newWindow) }
        openLocation.onClick = { [weak self] in self?.choose(.openLocation) }
        find.onClick = { [weak self] in self?.choose(.find) }
        reload.onClick = { [weak self] in self?.choose(.reloadOrStop) }
        pin.onClick = { [weak self] in self?.choose(.togglePin) }
        copyLink.onClick = { [weak self] in self?.choose(.copyLink) }
        share.onClick = { [weak self] in self?.choose(.share) }
        extensions.onClick = { [weak self] in self?.choose(.extensions) }
        settings.onClick = { [weak self] in self?.choose(.settings) }
        printPage.onClick = { [weak self] in self?.choose(.print) }
        fullScreen.onClick = { [weak self] in self?.choose(.toggleFullScreen) }
        zoom.onAction = { [weak self] action in self?.onAction?(action) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    var isPresented: Bool { !isHidden }

    /// Opens the menu with labels and controls reflecting the current tab and window.
    func present(state: MenuState) {
        update(state: state)
        isHidden = false
        alphaValue = 0
        card.frame.origin.y -= 6
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            animator().alphaValue = 1
            card.animator().frame.origin.y += 6
        }
    }

    /// Refreshes dynamic labels while leaving an open menu in place.
    func update(state: MenuState) {
        reload.set(symbol: state.isLoading ? "xmark" : "arrow.clockwise", title: state.isLoading ? "Stop Loading" : "Reload")
        reload.isEnabled = state.hasPage
        find.isEnabled = state.hasPage
        pin.set(symbol: state.isPinned ? "pin.slash" : "pin", title: state.isPinned ? "Unpin Tab" : "Pin Tab")
        pin.isEnabled = state.canPin
        copyLink.isEnabled = state.hasPage
        share.isEnabled = state.hasPage
        printPage.isEnabled = state.hasPage
        zoom.value = state.zoom
        fullScreen.set(
            symbol: state.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            title: state.isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
    }

    func dismiss() {
        guard isPresented else { return }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.12
                animator().alphaValue = 0
                card.animator().frame.origin.y -= 4
            },
            completionHandler: { [weak self] in
                guard let self, alphaValue == 0 else { return }
                isHidden = true
                card.frame.origin.y += 4
            })
    }

    override func layout() {
        super.layout()
        let width: CGFloat = 270
        let x = bounds.width - width - trailingInset
        let menuHeight: CGFloat = 514
        let height = max(180, min(menuHeight, bounds.height - 72))
        card.frame = NSRect(x: x, y: 58, width: width, height: height)
        scroll.frame = card.bounds
        scroll.hasVerticalScroller = height < menuHeight
        content.frame = NSRect(x: 0, y: 0, width: width, height: menuHeight)

        var y: CGFloat = 7
        for row in [newTab, newWindow] {
            row.frame = NSRect(x: 6, y: y, width: width - 12, height: 34)
            y += 34
        }
        separators[0].frame = NSRect(x: 12, y: y + 4, width: width - 24, height: 1)
        y += 10
        for row in [openLocation, find] {
            row.frame = NSRect(x: 6, y: y, width: width - 12, height: 34)
            y += 34
        }
        separators[1].frame = NSRect(x: 12, y: y + 4, width: width - 24, height: 1)
        y += 10
        for row in [reload, pin, copyLink, share, extensions, settings] {
            row.frame = NSRect(x: 6, y: y, width: width - 12, height: 34)
            y += 34
        }
        separators[2].frame = NSRect(x: 12, y: y + 4, width: width - 24, height: 1)
        y += 10
        zoom.frame = NSRect(x: 6, y: y, width: width - 12, height: 40)
        y += 40
        separators[3].frame = NSRect(x: 12, y: y + 4, width: width - 24, height: 1)
        y += 10
        for row in [printPage, fullScreen] {
            row.frame = NSRect(x: 6, y: y, width: width - 12, height: 34)
            y += 34
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }

    private func choose(_ action: MenuAction) {
        dismiss()
        onAction?(action)
    }
}

/// Keeps the browser menu's rows laid out from top to bottom inside its scroll view.
private final class MenuContent: NSView {
    override var isFlipped: Bool { true }
}

/// One icon, label and shortcut in the browser menu.
private final class MenuRow: NSView {
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private var symbol = ""
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, shortcut: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 13)
        self.shortcut.font = .systemFont(ofSize: 12)
        self.shortcut.stringValue = shortcut
        self.shortcut.alignment = .right
        [icon, label, self.shortcut].forEach(addSubview)
        set(symbol: symbol, title: title)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func set(symbol: String, title: String) {
        guard self.symbol != symbol || label.stringValue != title else { return }
        self.symbol = symbol
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        setAccessibilityLabel(title)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isHovered && isEnabled ? 0.08 : 0).cgColor
        let alpha: CGFloat = isEnabled ? 1 : 0.3
        icon.contentTintColor = NSColor.labelColor.withAlphaComponent(0.65 * alpha)
        label.textColor = NSColor.labelColor.withAlphaComponent(alpha)
        shortcut.textColor = NSColor.secondaryLabelColor.withAlphaComponent(alpha)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 9, width: 16, height: 16)
        label.frame = NSRect(x: 38, y: 8, width: bounds.width - 100, height: 18)
        shortcut.frame = NSRect(x: bounds.width - 62, y: 8, width: 50, height: 18)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        if isEnabled { onClick?() }
    }
}

/// The compact minus, percentage and plus control in the browser menu.
private final class MenuZoomRow: NSView {
    var onAction: ((MenuAction) -> Void)?
    var value: CGFloat = 1 { didSet { percentage.title = "\(Int((value * 100).rounded()))%" } }

    private let label = NSTextField(labelWithString: "Zoom")
    private let minus = NSButton(title: "−", target: nil, action: nil)
    private let percentage = NSButton(title: "100%", target: nil, action: nil)
    private let plus = NSButton(title: "+", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13)
        addSubview(label)
        for button in [minus, percentage, plus] {
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .medium)
            addSubview(button)
        }
        minus.target = self
        minus.action = #selector(zoomOut)
        percentage.target = self
        percentage.action = #selector(resetZoom)
        plus.target = self
        plus.action = #selector(zoomIn)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 38, y: 11, width: 64, height: 18)
        minus.frame = NSRect(x: bounds.width - 148, y: 6, width: 38, height: 28)
        percentage.frame = NSRect(x: bounds.width - 108, y: 6, width: 64, height: 28)
        plus.frame = NSRect(x: bounds.width - 42, y: 6, width: 38, height: 28)
    }

    @objc private func zoomOut() { onAction?(.zoomOut) }
    @objc private func resetZoom() { onAction?(.resetZoom) }
    @objc private func zoomIn() { onAction?(.zoomIn) }
}

/// A one-pixel division between groups in the browser menu.
private final class MenuSeparator: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.separatorColor.cgColor }
}
