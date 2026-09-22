import AppKit
import AuthenticationServices
import WebKit

/// One browser window: the tab strip on top, the active tab's web view below, and the address field
/// over it. Owns the tabs, pinned ones first; menu commands reach it through the responder chain.
final class WindowController: NSWindowController, NSWindowDelegate, WKWebExtensionWindow {
    private(set) var tabs: [Tab] = []
    let downloads: Downloads
    /// The tab whose page shows. Set only by `select`.
    private(set) var active: Tab?
    var collapsedGroups: Set<String> = []
    var onClose: (() -> Void)?

    let strip = Strip()
    private let content = NSView()
    private let omnibox = Omnibox()
    private let linkBubble = LinkBubble()
    private let menuPanel = MenuPanel()
    private let find = FindBar()
    private var scrollMonitor: Any?
    private var sleepTimer: Timer?
    weak var extensionActionAnchor: NSView?
    private weak var menuAnchor: NSView?
    /// Set by `registerWithExtensions`; until then the extension runtime is told nothing.
    var isRegisteredWithExtensions = false
    let isPrivate: Bool
    let extensionWindowType: WKWebExtension.WindowType
    private let privateStore: WKWebsiteDataStore?

    /// Constructs a hidden window. Extension transfers can start empty and omit saved pins.
    init(
        url: URL? = nil, isPrivate: Bool = false, configuration: WKWebViewConfiguration? = nil,
        windowType: WKWebExtension.WindowType = .normal, restorePins: Bool = true, startsEmpty: Bool = false
    ) {
        self.isPrivate = isPrivate
        extensionWindowType = windowType
        downloads = isPrivate ? Downloads() : .shared
        privateStore = isPrivate ? .nonPersistent() : nil
        let window = Window(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty toolbar makes this a toolbar window: the system gives it the taller titlebar, the
        // inset traffic lights and the larger corner radius, and the tab strip is laid out to fill that titlebar.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .textBackgroundColor
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Browser")
        super.init(window: window)
        window.delegate = self

        let root = RootView(
            strip: strip, content: content, linkBubble: linkBubble, omnibox: omnibox, menuPanel: menuPanel, find: find)
        window.contentView = root
        strip.controller = self
        downloadsDidChange()
        extensionsDidChange()
        omnibox.onNavigate = { [weak self] in self?.navigate(to: $0) }
        omnibox.onDismiss = { [weak self] in self?.dismissOmnibox() }
        omnibox.onTextChange = { [weak self] text in self?.active?.omniboxDraft = text }
        omnibox.onBackgroundChange = { [weak self] in
            guard let self, let active, active.isBlank else { return }
            applyTint(of: active)
        }
        menuPanel.onAction = { [weak self] in self?.performMenuAction($0) }

        // Tells the tab the user is scrolling, so it holds off anything that would make the page stutter.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.window { active?.pageTint.userIsScrolling() }
            return event
        }

        // Once a minute is often enough to notice a tab that has been hidden for half an hour.
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.sleepIdleTabs() }
        sleepTimer?.tolerance = 30

        tabs = (isPrivate || windowType != .normal || !restorePins ? [] : PinnedTabs.urls).map { url in
            let tab = Tab(pinnedAt: url)
            tab.owner = self
            return tab
        }
        if !startsEmpty { openTab(url: url, configuration: configuration) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Tabs

    /// Transfers a live public tab without closing it or replacing its page. Both windows must be ordinary.
    @discardableResult
    func transfer(_ tab: Tab, to index: Int) -> Bool {
        guard !isPrivate, tab.recordsActivity, let source = tab.owner, !source.isPrivate,
            let old = source.tabs.firstIndex(where: { $0 === tab })
        else { return false }
        if source === self {
            moveExtensionTab(tab, to: index)
            return true
        }
        let oldPublic = source.tabs.filter(\.recordsActivity).firstIndex { $0 === tab }!
        tab.webView.removeFromSuperview()
        source.tabs.remove(at: old)
        var replacement: Tab?
        if source.active === tab {
            source.active = nil
            replacement = source.tabs.dropFirst(min(old, source.tabs.count)).first ?? source.tabs.last
        }
        tab.opener = nil
        for child in source.tabs where child.opener === tab { child.opener = nil }
        tab.owner = self
        tab.hiddenSince = Date()
        let proposed = WebExtensions.insertionIndex(index, visibility: tabs.map(\.recordsActivity))
        let pins = tabs.filter(\.isPinned).count
        tabs.insert(tab, at: tab.isPinned ? min(proposed, pins) : max(proposed, pins))
        if source.isRegisteredWithExtensions || isRegisteredWithExtensions {
            WebExtensions.shared.controller.didMoveTab(tab, from: oldPublic, in: source)
        }
        if let replacement { source.select(replacement) }
        if active == nil { select(tab) } else { updateStrip() }
        if source.tabs.isEmpty { source.close() } else { source.updateStrip() }
        return true
    }

    /// Adds a tab at the end. With no URL it is blank. Background tabs load without being selected.
    @discardableResult
    func openTab(
        url: URL? = nil, configuration: WKWebViewConfiguration? = nil, inBackground: Bool = false, useNewTabOverride: Bool = true,
        scriptOpened: Bool = false, opener: Tab? = nil
    ) -> Tab {
        let override = useNewTabOverride && !isPrivate && url == nil && configuration == nil ? WebExtensions.shared.newTabContext : nil
        var configuration = configuration ?? override?.webViewConfiguration
        if let privateStore {
            if configuration?.websiteDataStore.isPersistent != false { configuration = Tab.configuration(ephemeral: true) }
            configuration?.websiteDataStore = privateStore
            configuration?.webExtensionController = nil
        }
        let tab = Tab(configuration: configuration, scriptOpened: scriptOpened)
        tab.isNewTabOverride = override != nil
        tab.owner = self
        tab.opener = opener
        tabs.append(tab)
        if isRegisteredWithExtensions, tab.recordsActivity { WebExtensions.shared.controller.didOpenTab(tab) }
        if let destination = url ?? override?.overrideNewTabPageURL { tab.load(destination) }
        tab.hiddenSince = Date()
        if inBackground { updateStrip() } else { select(tab) }
        return tab
    }

    /// Opens a URL handed over by another app, reusing the current tab if it is still blank.
    func openExternal(_ url: URL) {
        if active?.isBlank == true { navigate(to: url) } else { openTab(url: url) }
    }

    func select(_ tab: Tab) {
        let expanded = tab.groupName.map { collapsedGroups.remove($0) != nil } ?? false
        guard tab !== active else { if expanded { updateStrip() }; return }
        menuPanel.dismiss()
        find.dismiss()
        linkBubble.dismiss()
        let previous = active
        active?.webView.removeFromSuperview()
        previous?.hiddenSince = Date()
        tab.hiddenSince = nil
        active = tab
        omnibox.allowsRemoteSuggestions = tab.recordsActivity && !isPrivate
        tab.webView.frame = content.bounds
        tab.webView.autoresizingMask = [.width, .height]
        content.addSubview(tab.webView)
        tab.loadIfPending()

        if tab.isBlank || tab.isOmniboxOpen {
            omnibox.present(text: tab.omniboxDraft, overPage: !tab.isBlank, suggesting: tab.omniboxDraft != address(of: tab))
        } else {
            omnibox.dismiss()
            window?.makeFirstResponder(tab.webView)
        }
        tabDidChange(tab)
        tab.pageTint.resume()
        if isRegisteredWithExtensions, tab.recordsActivity {
            WebExtensions.shared.controller.didActivateTab(tab, previousActiveTab: previous?.recordsActivity == true ? previous : nil)
        }
    }

    /// Replaces an extension-bound page when its tab begins ordinary browsing.
    func replaceView(for tab: Tab, previous: WKWebView) {
        previous.removeFromSuperview()
        guard tab === active else { return }
        tab.webView.frame = content.bounds
        tab.webView.autoresizingMask = [.width, .height]
        content.addSubview(tab.webView)
        if !tab.isOmniboxOpen { window?.makeFirstResponder(tab.webView) }
    }

    /// Closes the tab and selects its right neighbor (or the left one at the end). Pinned tabs stay:
    /// closing one only moves on to the nearest ordinary tab. When the tab being left was the last
    /// ordinary one, the window closes.
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tab.isPinned {
            guard let next = tabs.first(where: { !$0.isPinned }) else { return close() }
            return select(next)
        }
        tab.cancelAuthentication()
        ClosedTabs.remember(tab)
        tabs.remove(at: index)
        if isRegisteredWithExtensions, tab.recordsActivity { WebExtensions.shared.controller.didCloseTab(tab) }
        if tab === active {
            guard tabs.contains(where: { !$0.isPinned }) else { return close() }
            select(tabs[min(index, tabs.count - 1)])
        }
        tab.webView.removeFromSuperview()
        updateStrip()
    }

    /// Opens an app-initiated sign-in flow, isolating cookies when the caller requests an ephemeral session.
    func openAuthentication(_ request: ASWebAuthenticationSessionRequest) {
        let tab = openTab(configuration: Tab.configuration(ephemeral: request.shouldUseEphemeralSession))
        tab.loadAuthentication(request)
    }

    /// Closes the tab for a sign-in flow canceled by its originating app.
    func cancelAuthentication(_ request: ASWebAuthenticationSessionRequest) {
        guard let tab = tabs.first(where: { $0.authenticationRequestID == request.uuid }) else { return }
        tab.authenticationWasCancelled()
        close(tab)
    }

    /// Loads `url` in the active tab and hands focus to the page.
    func navigate(to url: URL) {
        guard let active else { return }
        active.load(url)
        dismissOmnibox()
    }

    /// Called by tabs whenever their title, URL or loading state changes.
    func tabDidChange(_ tab: Tab, extensionProperties: WKWebExtension.TabChangedProperties = []) {
        if isRegisteredWithExtensions, tab.recordsActivity, !extensionProperties.isEmpty {
            WebExtensions.shared.controller.didChangeTabProperties(extensionProperties, for: tab)
        }
        updateStrip()
        guard tab === active else { return }
        window?.title = tab.title
        applyTint(of: tab)
    }

    /// Called when the pointer moves onto a link in a tab's page, or off it with nil. Only the page
    /// that shows has a pointer over it; a report from any other is late and is dropped.
    func tab(_ tab: Tab, isOverLink address: String?) {
        if tab === active { linkBubble.show(address) }
    }

    /// Called when a tab's page is replaced: what the pointer was over is gone with it.
    func tabDidLeavePage(_ tab: Tab) {
        if tab === active { linkBubble.dismiss() }
    }

    /// Called by tabs when only their top edge changed, which happens continuously while scrolling.
    /// Only this change is the page's own, so only it is made with the page's fade.
    func tabTintDidChange(_ tab: Tab) {
        if tab === active { applyTint(of: tab, fading: tab.tintFade) }
    }

    /// Makes the chrome read as part of the tab's page: the strip takes the color along the page's top
    /// edge, the window behind takes the page's background, and strip and traffic lights are drawn light
    /// or dark to stay legible. This runs on every sample while scrolling, so it only touches what
    /// changed. The window's own appearance is left alone: pages take their color scheme from it.
    /// `fading` is the fade the page is making to this color; a change of tab has none.
    /// A blank tab shows the native address view, so its background supplies the tint instead of WebKit.
    private func applyTint(of tab: Tab, fading: PageTint.Fade? = nil) {
        guard let window else { return }
        let color = tab.isBlank ? omnibox.pageBackground : tab.tint
        strip.setTint(color, fading: fading)

        let background = tab.isBlank ? color : tab.webView.underPageBackgroundColor
        if window.backgroundColor != background ?? .textBackgroundColor { window.backgroundColor = background ?? .textBackgroundColor }

        var name: NSAppearance.Name?
        if let rgb = color?.usingColorSpace(.sRGB) {
            let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            name = luminance < 0.5 ? .darkAqua : .aqua
        }
        if strip.appearance?.name != name {
            let appearance = name.flatMap(NSAppearance.init(named:))
            strip.appearance = appearance
            window.standardWindowButton(.closeButton)?.superview?.appearance = appearance
        }
    }

    /// Lets tabs hidden for `minimum` give up their pages; see `Tab.sleepIfIdle`.
    func sleepIdleTabs(hiddenFor minimum: TimeInterval? = nil) {
        guard Settings.sleepTabs else { return }
        tabs.forEach { $0.sleepIfIdle(hiddenFor: minimum ?? Double(Settings.sleepMinutes) * 60) }
    }

    /// Shows or drops the tabs' icons after the favicons setting changes.
    func faviconsSettingChanged() {
        tabs.forEach { $0.faviconsSettingChanged() }
        updateStrip()
    }

    func updateStrip() {
        (NSApp.delegate as? AppDelegate)?.scheduleSessionSave()
        strip.update(tabs: tabs, active: active)
        if menuPanel.isPresented { menuPanel.update(state: menuState) }
    }

    /// Opens or closes the custom browser menu anchored beneath the right edge of the strip.
    func toggleMenuPanel(relativeTo view: NSView) {
        menuAnchor = view
        if menuPanel.isPresented {
            menuPanel.dismiss()
        } else {
            find.dismiss()
            menuPanel.present(state: menuState)
        }
    }

    private var menuState: MenuState {
        MenuState(
            isLoading: active?.webView.isLoading ?? false,
            hasPage: active?.isBlank == false,
            canPin: active?.isBlank == false && active?.recordsActivity == true,
            isPinned: active?.isPinned ?? false,
            zoom: active?.webView.pageZoom ?? 1,
            isFullScreen: window?.styleMask.contains(.fullScreen) ?? false)
    }

    private func performMenuAction(_ action: MenuAction) {
        switch action {
        case .newTab: newTab(nil)
        case .newWindow: (NSApp.delegate as? AppDelegate)?.newWindow(nil)
        case .newPrivateWindow: (NSApp.delegate as? AppDelegate)?.newPrivateWindow(nil)
        case .history: openHistoryPage(nil)
        case .bookmarks: openBookmarksPage(nil)
        case .bookmarkPage: bookmarkPage(nil)
        case .tabGroups: showTabGroups(nil)
        case .reopenClosedTab: reopenClosedTab(nil)
        case .downloads: openDownloads(nil)
        case .clearBrowsingData: deleteBrowsingData(nil)
        case .about: NSApp.orderFrontStandardAboutPanel(nil)
        case .openLocation: openLocation(nil)
        case .find: findPage(nil)
        case .reloadOrStop:
            if active?.webView.isLoading == true { stopLoadingPage(nil) } else { reloadPage(nil) }
        case .togglePin: togglePin(nil)
        case .copyLink:
            if let active { copyLink(of: active) }
        case .share:
            if let url = active?.webView.url, let anchor = menuAnchor {
                NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            }
        case .extensions:
            if let anchor = menuAnchor { showExtensions(relativeTo: anchor) }
        case .settings: openSettings(nil)
        case .zoomOut: zoomOutPage(nil)
        case .resetZoom: resetPageZoom(nil)
        case .zoomIn: zoomInPage(nil)
        case .print: printPage(nil)
        case .toggleFullScreen: window?.toggleFullScreen(nil)
        }
        if menuPanel.isPresented { menuPanel.update(state: menuState) }
    }

    /// Puts a tab's address on the clipboard. Tabs with no page yet have nothing to copy.
    func copyLink(of tab: Tab) {
        guard let url = tab.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func dismissOmnibox() {
        guard let active, !active.isBlank else { return }
        active.isOmniboxOpen = false
        omnibox.dismiss()
        window?.makeFirstResponder(active.webView)
    }

    // MARK: Pins

    /// Moves a tab without crossing the pinned boundary and reports its former index to extensions.
    func move(_ tab: Tab, to index: Int) {
        guard let old = tabs.firstIndex(where: { $0 === tab }) else { return }
        let oldPublic = tabs.filter(\.recordsActivity).firstIndex { $0 === tab }
        tabs.remove(at: old)
        let pinCount = tabs.filter(\.isPinned).count
        let target = tab.isPinned ? min(max(0, index), pinCount) : min(max(pinCount, index), tabs.count)
        tabs.insert(tab, at: target)
        if isRegisteredWithExtensions, let oldPublic { WebExtensions.shared.controller.didMoveTab(tab, from: oldPublic, in: self) }
        updateStrip()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard !isPrivate, let entry = ClosedTabs.take() else { return }
        let tab = openTab(inBackground: true, useNewTabOverride: false)
        tab.groupName = entry.group
        tab.restore(url: entry.url, state: entry.state)
        select(tab)
        updateStrip()
    }

    /// Pins the tab at its current address, moving it to the end of the pinned tabs, or unpins it,
    /// making it the first ordinary tab. Blank and ephemeral tabs can't be pinned.
    func setPinned(_ pinned: Bool, tab: Tab) {
        guard pinned != tab.isPinned, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if pinned {
            guard tab.recordsActivity, let url = tab.url else { return }
            tab.groupName = nil
            tab.pinnedURL = url
            PinnedTabs.urls.append(url)
        } else {
            if let stored = PinnedTabs.urls.firstIndex(of: tab.pinnedURL!) { PinnedTabs.urls.remove(at: stored) }
            tab.pinnedURL = nil
        }
        tabs.remove(at: index)
        tabs.insert(tab, at: tabs.filter(\.isPinned).count)
        if isRegisteredWithExtensions {
            WebExtensions.shared.controller.didChangeTabProperties(.pinned, for: tab)
        }
        updateStrip()
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) { openTab() }
    @objc func closeTab(_ sender: Any?) { active.map(close) }

    @objc func openLocation(_ sender: Any?) {
        guard let active else { return }
        menuPanel.dismiss()
        find.dismiss()
        linkBubble.dismiss()
        let text = address(of: active)
        active.omniboxDraft = text
        active.isOmniboxOpen = true
        omnibox.present(text: text, overPage: !active.isBlank, selectingText: false, suggesting: false)
    }

    /// The page's address as the address field shows it; empty before a tab has a page.
    private func address(of tab: Tab) -> String { tab.webView.url.map(AddressInput.display(for:)) ?? "" }

    @objc func reloadPage(_ sender: Any?) { active?.reload() }
    @objc func stopLoadingPage(_ sender: Any?) { active?.webView.stopLoading() }
    @objc func goBackInHistory(_ sender: Any?) { active?.webView.goBack() }
    @objc func goForwardInHistory(_ sender: Any?) { active?.webView.goForward() }
    @objc func findPage(_ sender: Any?) {
        menuPanel.dismiss()
        if let webView = active?.webView, active?.isBlank == false { find.present(for: webView) }
    }
    @objc func printPage(_ sender: Any?) {
        active?.webView.printOperation(with: .shared).run()
    }

    @objc func zoomInPage(_ sender: Any?) { setPageZoom((active?.webView.pageZoom ?? 1) * 1.1) }
    @objc func zoomOutPage(_ sender: Any?) { setPageZoom((active?.webView.pageZoom ?? 1) / 1.1) }
    @objc func resetPageZoom(_ sender: Any?) { setPageZoom(1) }

    @objc func selectNextTab(_ sender: Any?) { selectTab(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { selectTab(offset: -1) }

    /// Command-1 through Command-8 pick a tab by position; Command-9 picks the last one.
    func selectTab(number: Int) -> Bool {
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return false }
        select(tabs[index])
        return true
    }

    /// Pins the current tab, or unpins it if it already is.
    @objc func togglePin(_ sender: Any?) {
        if let active { setPinned(!active.isPinned, tab: active) }
    }

    private func selectTab(offset: Int) {
        guard let active, let index = tabs.firstIndex(where: { $0 === active }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    private func setPageZoom(_ zoom: CGFloat) {
        guard let active else { return }
        active.setUserZoom(zoom)
        if isRegisteredWithExtensions, active.recordsActivity {
            WebExtensions.shared.controller.didChangeTabProperties(.zoomFactor, for: active)
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        // AppKit can ask on the second mouse-up, after the clicked control has already changed the strip.
        guard let event = NSApp.currentEvent, event.clickCount >= 2 else { return true }
        return (window as? Window)?.firstClickAllowsZoom == true
            && strip.allowsWindowZoom(at: event.locationInWindow)
    }

    /// Allows titlebar zoom only when the click begins on genuinely empty strip space.
    func allowsWindowZoom(at pointInWindow: NSPoint) -> Bool { strip.allowsWindowZoom(at: pointInWindow) }

    func windowWillClose(_ notification: Notification) {
        if isPrivate { downloads.endPrivateSession() }
        if isRegisteredWithExtensions {
            tabs.filter(\.recordsActivity).forEach { WebExtensions.shared.controller.didCloseTab($0, windowIsClosing: true) }
            WebExtensions.shared.controller.didCloseWindow(self)
        }
        scrollMonitor.map(NSEvent.removeMonitor)
        scrollMonitor = nil
        sleepTimer?.invalidate()
        sleepTimer = nil
        tabs.forEach { $0.webView.removeFromSuperview() }
        tabs = []
        active = nil
        onClose?()
    }

    // The system puts the traffic lights back at their own size whenever it lays the titlebar out again.
    func windowDidBecomeKey(_ notification: Notification) {
        window?.contentView?.needsLayout = true
        WebExtensions.shared.controller.didFocusWindow(extensionFocusTarget)
    }
    func windowDidResignKey(_ notification: Notification) {
        window?.contentView?.needsLayout = true
        WebExtensions.shared.controller.didFocusWindow(nil)
    }
    func windowDidResize(_ notification: Notification) { (NSApp.delegate as? AppDelegate)?.scheduleSessionSave() }
    func windowDidMove(_ notification: Notification) { (NSApp.delegate as? AppDelegate)?.scheduleSessionSave() }
    func windowDidEnterFullScreen(_ notification: Notification) { window?.contentView?.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { window?.contentView?.needsLayout = true }
}
