import AppKit
import AuthenticationServices
import WebKit

/// One browser window: the tab strip on top, the active tab's web view below, and the address field
/// over it. Owns the tabs, pinned ones first; menu commands reach it through the responder chain.
final class WindowController: NSWindowController, NSWindowDelegate, WKWebExtensionWindow {
    private(set) var tabs: [Tab] = []
    let downloads = Downloads()
    /// The tab whose page shows. Set only by `select`.
    private(set) var active: Tab?
    var onClose: (() -> Void)?

    let strip = Strip()
    private let content = NSView()
    private let omnibox = Omnibox()
    private let menuPanel = MenuPanel()
    private let find = FindBar()
    private var scrollMonitor: Any?
    private var sleepTimer: Timer?
    weak var extensionActionAnchor: NSView?
    private weak var menuAnchor: NSView?
    /// Set by `registerWithExtensions`; until then the extension runtime is told nothing.
    var isRegisteredWithExtensions = false

    /// Opens a window with one tab: `url` if given, otherwise a blank tab with the address field focused.
    init(url: URL? = nil) {
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

        let root = RootView(strip: strip, content: content, omnibox: omnibox, menuPanel: menuPanel, find: find)
        window.contentView = root
        strip.controller = self
        downloads.onChange = { [weak self] in self?.downloadsDidChange() }
        extensionsDidChange()
        omnibox.onNavigate = { [weak self] in self?.navigate(to: $0) }
        omnibox.onDismiss = { [weak self] in self?.dismissOmnibox() }
        omnibox.onTextChange = { [weak self] text in self?.active?.omniboxDraft = text }
        menuPanel.onAction = { [weak self] in self?.performMenuAction($0) }

        // Tells the tab the user is scrolling, so it holds off anything that would make the page stutter.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.window { active?.pageTint.userIsScrolling() }
            return event
        }

        // Once a minute is often enough to notice a tab that has been hidden for half an hour.
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.sleepIdleTabs() }
        sleepTimer?.tolerance = 30

        tabs = PinnedTabs.urls.map { url in
            let tab = Tab(pinnedAt: url)
            tab.owner = self
            return tab
        }
        openTab(url: url)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Tabs

    /// Adds a tab at the end. With no URL it is blank. Background tabs load without being selected.
    @discardableResult
    func openTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, inBackground: Bool = false) -> Tab {
        let tab = Tab(configuration: configuration)
        tab.owner = self
        tabs.append(tab)
        if isRegisteredWithExtensions { WebExtensions.shared.controller.didOpenTab(tab) }
        if let url { tab.load(url) }
        tab.hiddenSince = Date()
        if inBackground { updateStrip() } else { select(tab) }
        return tab
    }

    /// Opens a URL handed over by another app, reusing the current tab if it is still blank.
    func openExternal(_ url: URL) {
        if active?.isBlank == true { navigate(to: url) } else { openTab(url: url) }
    }

    func select(_ tab: Tab) {
        guard tab !== active else { return }
        menuPanel.dismiss()
        find.dismiss()
        let previous = active
        active?.webView.removeFromSuperview()
        previous?.hiddenSince = Date()
        tab.hiddenSince = nil
        active = tab
        tab.webView.frame = content.bounds
        tab.webView.autoresizingMask = [.width, .height]
        content.addSubview(tab.webView)
        tab.loadIfPending()

        if tab.isBlank || tab.isOmniboxOpen {
            omnibox.present(text: tab.omniboxDraft, overPage: !tab.isBlank)
        } else {
            omnibox.dismiss()
            window?.makeFirstResponder(tab.webView)
        }
        tabDidChange(tab)
        tab.pageTint.resume()
        if isRegisteredWithExtensions {
            WebExtensions.shared.controller.didActivateTab(tab, previousActiveTab: previous)
        }
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
        tabs.remove(at: index)
        if isRegisteredWithExtensions { WebExtensions.shared.controller.didCloseTab(tab) }
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
        if isRegisteredWithExtensions, !extensionProperties.isEmpty {
            WebExtensions.shared.controller.didChangeTabProperties(extensionProperties, for: tab)
        }
        updateStrip()
        guard tab === active else { return }
        window?.title = tab.title
        applyTint(of: tab)
    }

    /// Called by tabs when only their top edge changed, which happens continuously while scrolling.
    func tabTintDidChange(_ tab: Tab) {
        if tab === active { applyTint(of: tab) }
    }

    /// Makes the chrome read as part of the tab's page: the strip takes the color along the page's top
    /// edge, the window behind takes the page's background, and strip and traffic lights are drawn light
    /// or dark to stay legible. This runs on every sample while scrolling, so it only touches what
    /// changed. The window's own appearance is left alone: pages take their color scheme from it.
    private func applyTint(of tab: Tab) {
        guard let window else { return }
        let color = tab.tint
        strip.setTint(color, fading: tab.tintFade)

        let background = tab.isBlank ? nil : tab.webView.underPageBackgroundColor
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
    func sleepIdleTabs(hiddenFor minimum: TimeInterval = Tab.sleepAfter) {
        tabs.forEach { $0.sleepIfIdle(hiddenFor: minimum) }
    }

    /// Shows or drops the tabs' icons after the favicons setting changes.
    func faviconsSettingChanged() {
        tabs.forEach { $0.faviconsSettingChanged() }
        updateStrip()
    }

    func updateStrip() {
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
            canPin: active?.isBlank == false,
            isPinned: active?.isPinned ?? false,
            zoom: active?.webView.pageZoom ?? 1,
            isFullScreen: window?.styleMask.contains(.fullScreen) ?? false)
    }

    private func performMenuAction(_ action: MenuAction) {
        switch action {
        case .newTab: newTab(nil)
        case .newWindow: (NSApp.delegate as? AppDelegate)?.newWindow(nil)
        case .openLocation: openLocation(nil)
        case .find: findPage(nil)
        case .reloadOrStop:
            if active?.webView.isLoading == true { stopLoadingPage(nil) } else { reloadPage(nil) }
        case .togglePin: togglePin(nil)
        case .copyLink:
            if let url = active?.webView.url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
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

    private func dismissOmnibox() {
        guard let active, !active.isBlank else { return }
        active.isOmniboxOpen = false
        omnibox.dismiss()
        window?.makeFirstResponder(active.webView)
    }

    // MARK: PinnedTabs

    /// PinnedTabs the tab at its current address, moving it to the end of the pinned tabs, or unpins it,
    /// making it the first ordinary tab. Blank tabs can't be pinned.
    func setPinned(_ pinned: Bool, tab: Tab) {
        guard pinned != tab.isPinned, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if pinned {
            guard let url = tab.webView.url else { return }
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
        let text = active.webView.url.map(AddressInput.display(for:)) ?? ""
        active.omniboxDraft = text
        active.isOmniboxOpen = true
        omnibox.present(text: text, overPage: !active.isBlank)
    }

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

    /// PinnedTabs the current tab, or unpins it if it already is.
    @objc func togglePin(_ sender: Any?) {
        if let active { setPinned(!active.isPinned, tab: active) }
    }

    private func selectTab(offset: Int) {
        guard let active, let index = tabs.firstIndex(where: { $0 === active }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    private func setPageZoom(_ zoom: CGFloat) {
        guard let active else { return }
        active.webView.pageZoom = zoom
        if isRegisteredWithExtensions {
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
        if isRegisteredWithExtensions {
            tabs.forEach { WebExtensions.shared.controller.didCloseTab($0, windowIsClosing: true) }
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
        WebExtensions.shared.controller.didFocusWindow(self)
    }
    func windowDidResignKey(_ notification: Notification) { window?.contentView?.needsLayout = true }
    func windowDidEnterFullScreen(_ notification: Notification) { window?.contentView?.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { window?.contentView?.needsLayout = true }
}
