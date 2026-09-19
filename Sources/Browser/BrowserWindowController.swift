import AppKit
import WebKit

/// One browser window: the tab strip on top, the active tab's web view below, and the address field
/// over it. Owns the tabs, pinned ones first; menu commands reach it through the responder chain.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private(set) var tabs: [Tab] = []
    private var active: Tab?
    var onClose: (() -> Void)?

    private let strip = TabStripView()
    private let content = NSView()
    private let omnibox = OmniboxView()
    private var scrollMonitor: Any?

    /// Opens a window with one tab: `url` if given, otherwise a blank tab with the address field focused.
    init(url: URL? = nil) {
        let window = NSWindow(
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

        let root = RootView(strip: strip, content: content, omnibox: omnibox)
        window.contentView = root
        strip.controller = self
        omnibox.onNavigate = { [weak self] in self?.navigate(to: $0) }
        omnibox.onDismiss = { [weak self] in self?.dismissOmnibox() }

        // Tells the tab the user is scrolling, so it holds off anything that would make the page stutter.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.window { active?.edge.userIsScrolling() }
            return event
        }

        tabs = Pins.urls.map { url in
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
        if let url { tab.load(url) }
        if inBackground { updateStrip() } else { select(tab) }
        return tab
    }

    /// Opens a URL handed over by another app, reusing the current tab if it is still blank.
    func openExternal(_ url: URL) {
        if active?.isBlank == true { navigate(to: url) } else { openTab(url: url) }
    }

    func select(_ tab: Tab) {
        guard tab !== active else { return }
        active?.webView.removeFromSuperview()
        active = tab
        tab.webView.frame = content.bounds
        tab.webView.autoresizingMask = [.width, .height]
        content.addSubview(tab.webView)
        tab.loadIfPending()

        if tab.isBlank {
            omnibox.present(text: "", overPage: false)
        } else {
            dismissOmnibox()
        }
        tabDidChange(tab)
        tab.edge.resume()
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
        tabs.remove(at: index)
        if tab === active {
            guard tabs.contains(where: { !$0.isPinned }) else { return close() }
            select(tabs[min(index, tabs.count - 1)])
        }
        tab.webView.removeFromSuperview()
        updateStrip()
    }

    /// Loads `url` in the active tab and hands focus to the page.
    func navigate(to url: URL) {
        guard let active else { return }
        active.load(url)
        dismissOmnibox()
    }

    /// Called by tabs whenever their title, URL or loading state changes.
    func tabDidChange(_ tab: Tab) {
        updateStrip()
        guard tab === active else { return }
        window?.title = tab.title
        applyChrome(of: tab)
    }

    /// Called by tabs when only their top edge changed, which happens continuously while scrolling.
    func tabChromeDidChange(_ tab: Tab) {
        if tab === active { applyChrome(of: tab) }
    }

    /// Makes the chrome read as part of the tab's page: the strip takes the color along the page's top
    /// edge, the window behind takes the page's background, and strip and traffic lights are drawn light
    /// or dark to stay legible. This runs on every sample while scrolling, so it only touches what
    /// changed. The window's own appearance is left alone: pages take their color scheme from it.
    private func applyChrome(of tab: Tab) {
        guard let window else { return }
        let color = tab.chromeColor
        strip.pageColor = color

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

    private func updateStrip() {
        strip.update(tabs: tabs, active: active)
    }

    private func dismissOmnibox() {
        guard let active, !active.isBlank else { return }
        omnibox.dismiss()
        window?.makeFirstResponder(active.webView)
    }

    // MARK: Pins

    /// Pins the tab at its current address, moving it to the end of the pinned tabs, or unpins it,
    /// making it the first ordinary tab. Blank tabs can't be pinned.
    func setPinned(_ pinned: Bool, tab: Tab) {
        guard pinned != tab.isPinned, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if pinned {
            guard let url = tab.webView.url else { return }
            tab.pinnedURL = url
            Pins.urls.append(url)
        } else {
            if let stored = Pins.urls.firstIndex(of: tab.pinnedURL!) { Pins.urls.remove(at: stored) }
            tab.pinnedURL = nil
        }
        tabs.remove(at: index)
        tabs.insert(tab, at: tabs.filter(\.isPinned).count)
        updateStrip()
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) { openTab() }
    @objc func closeTab(_ sender: Any?) { active.map(close) }

    @objc func openLocation(_ sender: Any?) {
        guard let active else { return }
        let text = active.webView.url.map(AddressInput.display(for:)) ?? ""
        omnibox.present(text: text, overPage: !active.isBlank)
    }

    @objc func reloadPage(_ sender: Any?) { active?.webView.reload() }
    @objc func stopLoadingPage(_ sender: Any?) { active?.webView.stopLoading() }
    @objc func goBackInHistory(_ sender: Any?) { active?.webView.goBack() }
    @objc func goForwardInHistory(_ sender: Any?) { active?.webView.goForward() }

    @objc func zoomInPage(_ sender: Any?) { active?.webView.pageZoom *= 1.1 }
    @objc func zoomOutPage(_ sender: Any?) { active?.webView.pageZoom /= 1.1 }
    @objc func resetPageZoom(_ sender: Any?) { active?.webView.pageZoom = 1 }

    @objc func selectNextTab(_ sender: Any?) { selectTab(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { selectTab(offset: -1) }

    /// ⌘1–⌘8 pick a tab by position; ⌘9 picks the last one. The position is the menu item's tag.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        if tabs.indices.contains(index) { select(tabs[index]) }
    }

    /// Pins the current tab, or unpins it if it already is.
    @objc func togglePin(_ sender: Any?) {
        if let active { setPinned(!active.isPinned, tab: active) }
    }

    private func selectTab(offset: Int) {
        guard let active, let index = tabs.firstIndex(where: { $0 === active }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        scrollMonitor.map(NSEvent.removeMonitor)
        scrollMonitor = nil
        tabs.forEach { $0.webView.removeFromSuperview() }
        tabs = []
        active = nil
        onClose?()
    }

    // The system puts the traffic lights back at their own size whenever it lays the titlebar out again.
    func windowDidBecomeKey(_ notification: Notification) { window?.contentView?.needsLayout = true }
    func windowDidResignKey(_ notification: Notification) { window?.contentView?.needsLayout = true }
    func windowDidEnterFullScreen(_ notification: Notification) { window?.contentView?.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { window?.contentView?.needsLayout = true }
}

/// The addresses of the pinned tabs, kept in user defaults; every new window opens with them.
enum Pins {
    static var urls: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "pins") ?? []).compactMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue.map(\.absoluteString), forKey: "pins") }
    }
}

/// The window's content view: the strip fills the system titlebar area, content and address field fill the rest.
private final class RootView: NSView {
    private let strip: TabStripView, content: NSView, omnibox: NSView
    /// Kept from the last windowed layout, because in full screen the titlebar leaves the window.
    private var stripHeight: CGFloat = 52
    /// The traffic lights' frames as the system lays them out, captured before they are first enlarged.
    private var systemLights: [NSRect] = []

    init(strip: TabStripView, content: NSView, omnibox: NSView) {
        (self.strip, self.content, self.omnibox) = (strip, content, omnibox)
        super.init(frame: .zero)
        [content, omnibox, strip].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Draws the close, minimize and zoom buttons with 14pt discs instead of the system's 11.7pt, in
    /// proportion to the strip's 30pt items, keeping them the system's own buttons. Each gets a larger
    /// frame around its own center while its bounds stay at the system size, so AppKit scales its drawing
    /// and the whole disc stays clickable. Their spacing and horizontal positions stay the system's; only
    /// the size changes, and they center on the strip.
    private func enlargeTrafficLights(of window: NSWindow) {
        let scale: CGFloat = 1.2
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        guard buttons.count == 3, let titlebar = buttons[0].superview, !window.styleMask.contains(.fullScreen) else { return }
        if systemLights.isEmpty {
            systemLights = buttons.map(\.frame)
            // AppKit puts the buttons back whenever it lays the titlebar out, which a changed window title
            // is enough to cause. Undoing that at once keeps them from ever being seen out of place.
            for button in buttons {
                button.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(trafficLightMoved), name: NSView.frameDidChangeNotification, object: button)
            }
        }

        for (button, system) in zip(buttons, systemLights) {
            let size = NSSize(width: system.width * scale, height: system.height * scale)
            let frame = NSRect(
                x: system.midX - size.width / 2, y: (titlebar.bounds.height - size.height) / 2, width: size.width, height: size.height)
            if button.frame != frame {
                button.frame = frame
                button.setBoundsSize(system.size)
            }
        }
    }

    @objc private func trafficLightMoved() {
        if let window { enlargeTrafficLights(of: window) }
    }

    override func layout() {
        super.layout()
        if let window {
            let titlebarHeight = window.frame.height - window.contentLayoutRect.maxY
            if titlebarHeight > 0 { stripHeight = titlebarHeight }
            enlargeTrafficLights(of: window)
            // Tabs start right of the traffic lights, or at the edge when full screen hides them.
            let lights = window.standardWindowButton(.zoomButton)
            let lightsEnd = lights.map { $0.convert($0.bounds, to: nil).maxX } ?? 0
            strip.leadingInset = window.styleMask.contains(.fullScreen) ? 12 : lightsEnd + 18
        }
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        content.frame = NSRect(x: 0, y: stripHeight, width: bounds.width, height: bounds.height - stripHeight)
        omnibox.frame = content.frame
    }
}
