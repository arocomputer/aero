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
    case newPrivateWindow
    case history
    case downloads
    case clearBrowsingData
    case about
    case bookmarks
    case bookmarkPage
    case tabGroups
    case reopenClosedTab
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
    private let newTab = MenuRow(symbol: "rectangle.badge.plus", title: "New Tab", shortcut: "⌘T")
    private let newWindow = MenuRow(symbol: "macwindow.badge.plus", title: "New Window", shortcut: "⌘N")
    private let newPrivateWindow = MenuRow(symbol: "hand.raised", title: "New Private Window", shortcut: "⇧⌘N")
    private let openLocation = MenuRow(symbol: "magnifyingglass", title: "Open Location", shortcut: "⌘L")
    private let find = MenuRow(symbol: "text.magnifyingglass", title: "Find on Page", shortcut: "⌘F")
    private let reload = MenuRow(symbol: "arrow.clockwise", title: "Reload", shortcut: "⌘R")
    private let pin = MenuRow(symbol: "pin", title: "Pin Tab", shortcut: "")
    private let bookmarks = MenuRow(symbol: "bookmark", title: "Bookmarks", shortcut: "⌥⌘B")
    private let bookmarkPage = MenuRow(symbol: "star", title: "Bookmark This Page…", shortcut: "⌘D")
    private let tabGroups = MenuRow(symbol: "rectangle.3.group", title: "Tab Groups", shortcut: "")
    private let reopen = MenuRow(symbol: "arrow.uturn.backward", title: "Reopen Closed Tab", shortcut: "⇧⌘T")
    private let copyLink = MenuRow(symbol: "link", title: "Copy Page Link", shortcut: "")
    private let share = MenuRow(symbol: "square.and.arrow.up", title: "Share Page", shortcut: "")
    private let history = MenuRow(symbol: "clock.arrow.circlepath", title: "History", shortcut: "⌘Y")
    private let downloads = MenuRow(symbol: "arrow.down.to.line", title: "Downloads", shortcut: "⌥⌘L")
    private let extensions = MenuRow(symbol: "puzzlepiece.extension", title: "Extensions", shortcut: "")
    private let clearData = MenuRow(symbol: "trash", title: "Delete Browsing Data…", shortcut: "⇧⌘⌫")
    private let about = MenuRow(symbol: "info.circle", title: "About \(appName)", shortcut: "")
    private let settings = MenuRow(symbol: "gearshape", title: "Settings", shortcut: "⌘,")
    private let zoom = MenuZoomRow()
    private let printPage = MenuRow(symbol: "printer", title: "Print", shortcut: "⌘P")
    private let separators = [MenuSeparator(), MenuSeparator(), MenuSeparator(), MenuSeparator()]

    /// Groups follow the task: create, browsing records, zoom, current page, then app preferences.
    private var groups: [[NSView]] {
        [
            [newTab, newWindow, newPrivateWindow, reopen, openLocation],
            [history, downloads, bookmarks, tabGroups, extensions, clearData],
            [zoom],
            [printPage, find, reload, bookmarkPage, pin, copyLink, share],
            [about, settings],
        ]
    }

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

        groups.flatMap { $0 }.forEach(content.addSubview)
        separators.forEach(content.addSubview)

        newTab.onClick = { [weak self] in self?.choose(.newTab) }
        newWindow.onClick = { [weak self] in self?.choose(.newWindow) }
        newPrivateWindow.onClick = { [weak self] in self?.choose(.newPrivateWindow) }
        openLocation.onClick = { [weak self] in self?.choose(.openLocation) }
        find.onClick = { [weak self] in self?.choose(.find) }
        reload.onClick = { [weak self] in self?.choose(.reloadOrStop) }
        pin.onClick = { [weak self] in self?.choose(.togglePin) }
        copyLink.onClick = { [weak self] in self?.choose(.copyLink) }
        share.onClick = { [weak self] in self?.choose(.share) }
        extensions.onClick = { [weak self] in self?.choose(.extensions) }
        history.onClick = { [weak self] in self?.choose(.history) }
        downloads.onClick = { [weak self] in self?.choose(.downloads) }
        clearData.onClick = { [weak self] in self?.choose(.clearBrowsingData) }
        about.onClick = { [weak self] in self?.choose(.about) }
        bookmarks.onClick = { [weak self] in self?.choose(.bookmarks) }
        bookmarkPage.onClick = { [weak self] in self?.choose(.bookmarkPage) }
        tabGroups.onClick = { [weak self] in self?.choose(.tabGroups) }
        reopen.onClick = { [weak self] in self?.choose(.reopenClosedTab) }
        settings.onClick = { [weak self] in self?.choose(.settings) }
        printPage.onClick = { [weak self] in self?.choose(.print) }
        zoom.onAction = { [weak self] action in
            if case .toggleFullScreen = action { self?.choose(action) } else { self?.onAction?(action) }
        }
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
        bookmarkPage.isEnabled = state.hasPage
        reopen.isEnabled = !ClosedTabs.entries.isEmpty
        copyLink.isEnabled = state.hasPage
        share.isEnabled = state.hasPage
        printPage.isEnabled = state.hasPage
        zoom.value = state.zoom
        zoom.isFullScreen = state.isFullScreen
        zoom.pageEnabled = state.hasPage
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
        let width: CGFloat = 300
        let x = bounds.width - width - trailingInset
        let menuHeight = groups.flatMap { $0 }.reduce(CGFloat(14 + separators.count * 12)) { $0 + ($1 === zoom ? 38 : 32) }
        let height = max(180, min(menuHeight, bounds.height - 72))
        card.frame = NSRect(x: x, y: 58, width: width, height: height)
        scroll.frame = card.bounds
        scroll.hasVerticalScroller = height < menuHeight
        content.frame = NSRect(x: 0, y: 0, width: width, height: menuHeight)

        var y: CGFloat = 7
        for (index, rows) in groups.enumerated() {
            for row in rows {
                let rowHeight: CGFloat = row === zoom ? 38 : 32
                row.frame = NSRect(x: 6, y: y, width: width - 12, height: rowHeight)
                y += rowHeight
            }
            if index < separators.count {
                separators[index].frame = NSRect(x: 12, y: y + 5, width: width - 24, height: 1)
                y += 12
            }
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
    var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                needsDisplay = true
                setAccessibilityEnabled(isEnabled)
            }
        }
    }

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
        setAccessibilityRole(.button)
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
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
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
        icon.frame = NSRect(x: 10, y: 7, width: 18, height: 18)
        label.frame = NSRect(x: 38, y: 7, width: bounds.width - 100, height: 18)
        shortcut.frame = NSRect(x: bounds.width - 62, y: 7, width: 50, height: 18)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        if isEnabled { onClick?() }
    }
}

/// Zoom and full-screen controls share a row; selecting the percentage restores actual size.
private final class MenuZoomRow: NSView {
    var onAction: ((MenuAction) -> Void)?
    var value: CGFloat = 1 { didSet { percentage.title = "\(Int((value * 100).rounded()))%" } }
    var pageEnabled = true { didSet { [minus, percentage, plus].forEach { $0.isEnabled = pageEnabled } } }
    var isFullScreen = false {
        didSet {
            fullScreen.image = NSImage(
                systemSymbolName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
            fullScreen.toolTip = isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
        }
    }

    private let label = NSTextField(labelWithString: "Zoom")
    private let minus = NSButton(title: "−", target: nil, action: nil)
    private let percentage = NSButton(title: "100%", target: nil, action: nil)
    private let plus = NSButton(title: "+", target: nil, action: nil)
    private let fullScreen = NSButton()
    private let divider = MenuSeparator()
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13)
        addSubview(label)
        icon.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        addSubview(divider)
        for button in [minus, percentage, plus, fullScreen] {
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
        minus.setAccessibilityLabel("Zoom Out")
        percentage.setAccessibilityLabel("Reset Zoom")
        plus.setAccessibilityLabel("Zoom In")
        fullScreen.target = self
        fullScreen.action = #selector(toggleFullScreen)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 10, width: 18, height: 18)
        label.frame = NSRect(x: 38, y: 10, width: 52, height: 18)
        minus.frame = NSRect(x: bounds.width - 168, y: 5, width: 28, height: 28)
        percentage.frame = NSRect(x: bounds.width - 137, y: 5, width: 52, height: 28)
        plus.frame = NSRect(x: bounds.width - 82, y: 5, width: 28, height: 28)
        divider.frame = NSRect(x: bounds.width - 46, y: 10, width: 1, height: 18)
        fullScreen.frame = NSRect(x: bounds.width - 38, y: 5, width: 32, height: 28)
    }

    @objc private func zoomOut() { onAction?(.zoomOut) }
    @objc private func resetZoom() { onAction?(.resetZoom) }
    @objc private func zoomIn() { onAction?(.zoomIn) }
    @objc private func toggleFullScreen() { onAction?(.toggleFullScreen) }
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
