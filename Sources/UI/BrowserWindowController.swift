import AppKit
import AuthenticationServices
import WebKit

/// One browser window: the tab strip on top, the active tab's web view below, and the address field
/// over it. Owns the tabs, pinned ones first; menu commands reach it through the responder chain.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKWebExtensionWindow {
    private(set) var tabs: [Tab] = []
    let downloads = Downloads()
    private var active: Tab?
    var onClose: (() -> Void)?

    private let strip = TabStripView()
    private let content = NSView()
    private let omnibox = OmniboxView()
    private let browserMenu = BrowserMenuView()
    private let find = FindView()
    private var scrollMonitor: Any?
    weak var extensionActionAnchor: NSView?
    private weak var browserMenuAnchor: NSView?
    private var isRegisteredWithExtensions = false

    /// Opens a window with one tab: `url` if given, otherwise a blank tab with the address field focused.
    init(url: URL? = nil) {
        let window = BrowserWindow(
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

        let root = RootView(strip: strip, content: content, omnibox: omnibox, browserMenu: browserMenu, find: find)
        window.contentView = root
        strip.controller = self
        downloads.onChange = { [weak self] in self?.downloadsDidChange() }
        extensionsDidChange()
        omnibox.onNavigate = { [weak self] in self?.navigate(to: $0) }
        omnibox.onDismiss = { [weak self] in self?.dismissOmnibox() }
        omnibox.onTextChange = { [weak self] text in self?.active?.omniboxDraft = text }
        browserMenu.onAction = { [weak self] in self?.performBrowserMenuAction($0) }

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
        if isRegisteredWithExtensions { WebExtensions.shared.controller.didOpenTab(tab) }
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
        browserMenu.dismiss()
        find.dismiss()
        let previous = active
        active?.webView.removeFromSuperview()
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
        tab.edge.resume()
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
        if browserMenu.isPresented { browserMenu.update(state: browserMenuState) }
    }

    /// Announces a fully constructed window and its tabs to the shared extension runtime.
    func registerWithExtensions() {
        guard !isRegisteredWithExtensions else { return }
        isRegisteredWithExtensions = true
        let controller = WebExtensions.shared.controller
        controller.didOpenWindow(self)
        tabs.forEach(controller.didOpenTab)
        if let active { controller.didActivateTab(active) }
    }

    /// Shows current-session downloads from newest to oldest. Completed files open in Finder;
    /// running downloads can be cancelled without keeping their original tab alive.
    func showDownloads(relativeTo view: NSView) {
        let menu = NSMenu(title: "Downloads")
        for item in downloads.items {
            switch item.state {
            case .running:
                let percent = Int((item.progress * 100).rounded())
                let status = NSMenuItem(title: "\(item.filename) (\(percent)%)", action: nil, keyEquivalent: "")
                status.isEnabled = false
                menu.addItem(status)
                let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelDownload(_:)), keyEquivalent: "")
                cancel.target = self
                cancel.representedObject = item
                menu.addItem(cancel)
            case .finished:
                let reveal = NSMenuItem(title: item.filename, action: #selector(revealDownload(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = item
                menu.addItem(reveal)
            case let .failed(message):
                let failed = NSMenuItem(title: "\(item.filename): \(message)", action: nil, keyEquivalent: "")
                failed.isEnabled = false
                menu.addItem(failed)
            case .cancelled:
                let cancelled = NSMenuItem(title: "\(item.filename) (Cancelled)", action: nil, keyEquivalent: "")
                cancelled.isEnabled = false
                menu.addItem(cancelled)
            }
            if item !== downloads.items.last { menu.addItem(.separator()) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX, y: view.bounds.maxY + 4), in: view)
    }

    private func downloadsDidChange() {
        strip.showsDownloads = !downloads.items.isEmpty
    }

    @objc private func cancelDownload(_ sender: NSMenuItem) {
        (sender.representedObject as? DownloadItem)?.cancel()
    }

    @objc private func revealDownload(_ sender: NSMenuItem) {
        (sender.representedObject as? DownloadItem)?.reveal()
    }

    /// Shows extension actions for the current tab and a route to the full extensions page.
    func showExtensions(relativeTo view: NSView) {
        extensionActionAnchor = view
        let menu = NSMenu(title: "Extensions")
        for context in WebExtensions.shared.contexts {
            let extensionItem = NSMenuItem(title: context.webExtension.displayName ?? "Extension", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            if let action = context.action(for: active) {
                let actionItem = NSMenuItem(
                    title: action.label.isEmpty ? "Run" : action.label,
                    action: #selector(runExtensionAction(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = action
                actionItem.isEnabled = action.isEnabled
                actionItem.image = action.icon(for: NSSize(width: 16, height: 16))
                submenu.addItem(actionItem)
            }
            if context.optionsPageURL != nil {
                let options = NSMenuItem(title: "Options", action: #selector(openExtensionOptions(_:)), keyEquivalent: "")
                options.target = self
                options.representedObject = context
                submenu.addItem(options)
            }
            submenu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove", action: #selector(removeExtension(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = context
            submenu.addItem(remove)
            extensionItem.submenu = submenu
            menu.addItem(extensionItem)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let manage = NSMenuItem(title: "Manage Extensions...", action: #selector(openExtensionCatalog(_:)), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX, y: view.bounds.maxY + 4), in: view)
    }

    func extensionsDidChange() {
        updateStrip()
    }

    /// Opens or closes the custom browser menu anchored beneath the right edge of the strip.
    func toggleBrowserMenu(relativeTo view: NSView) {
        browserMenuAnchor = view
        if browserMenu.isPresented {
            browserMenu.dismiss()
        } else {
            find.dismiss()
            browserMenu.present(state: browserMenuState)
        }
    }

    private var browserMenuState: BrowserMenuState {
        BrowserMenuState(
            isLoading: active?.webView.isLoading ?? false,
            hasPage: active?.isBlank == false,
            canPin: active?.isBlank == false,
            isPinned: active?.isPinned ?? false,
            zoom: active?.webView.pageZoom ?? 1,
            isFullScreen: window?.styleMask.contains(.fullScreen) ?? false)
    }

    private func performBrowserMenuAction(_ action: BrowserMenuAction) {
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
            if let url = active?.webView.url, let anchor = browserMenuAnchor {
                NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            }
        case .extensions:
            if let anchor = browserMenuAnchor { showExtensions(relativeTo: anchor) }
        case .settings: openSettings(nil)
        case .zoomOut: zoomOutPage(nil)
        case .resetZoom: resetPageZoom(nil)
        case .zoomIn: zoomInPage(nil)
        case .print: printPage(nil)
        case .toggleFullScreen: window?.toggleFullScreen(nil)
        }
        if browserMenu.isPresented { browserMenu.update(state: browserMenuState) }
    }

    /// Handles privileged links from the bundled extensions page. Normal websites cannot use these
    /// actions because only the `aero` scheme reaches this method.
    func handleExtensionCatalogAction(_ url: URL, from tab: Tab) {
        let action = String(url.path.dropFirst("/action/".count))
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value
        let bundleIdentifier = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "bundle" })?.value
        switch action {
        case "refresh":
            tab.webView.reload()
        case "install-file":
            (NSApp.delegate as? AppDelegate)?.chooseExtension { tab.webView.reload() }
        case "open-store":
            if let id, let appID = Int(id), let url = ExtensionCatalog.storeURL(appID: appID) {
                NSWorkspace.shared.open(url)
            }
        case "install-native":
            guard let bundleIdentifier, ExtensionCatalog.canInstall(bundleIdentifier: bundleIdentifier) else { return }
            Task { @MainActor in
                do {
                    try await WebExtensions.shared.install(appBundleIdentifier: bundleIdentifier)
                    tab.webView.reload()
                } catch {
                    showExtensionError(error)
                }
            }
        case "options":
            if let id, let context = WebExtensions.shared.context(uniqueIdentifier: id), let url = context.optionsPageURL {
                openTab(url: url)
            }
        case "remove":
            if let id, let context = WebExtensions.shared.context(uniqueIdentifier: id) {
                confirmRemoval(of: context) { tab.webView.reload() }
            }
        default:
            break
        }
    }

    @objc private func openExtensionCatalog(_ sender: Any?) {
        if active?.webView.url == ExtensionCatalog.pageURL {
            active?.webView.reload()
        } else {
            openTab(url: ExtensionCatalog.pageURL)
        }
    }

    /// Opens Aero's local settings page from either the application menu or browser menu.
    @objc func openSettings(_ sender: Any?) {
        if active?.webView.url == SettingsPage.pageURL {
            active?.webView.reload()
        } else {
            openTab(url: SettingsPage.pageURL)
        }
    }

    /// Performs privileged settings-page actions after WebKit verifies they came from an Aero page.
    func handleSettingsAction(_ url: URL, from tab: Tab) {
        let action = String(url.path.dropFirst("/action/".count))
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "value" })?.value
        switch action {
        case "allow-passkeys":
            Passkeys.requestAccess { tab.webView.reload() }
        case "appearance":
            guard let value, let appearance = BrowserAppearance(rawValue: value) else { return }
            BrowserSettings.appearance = appearance
            tab.webView.reload()
        case "search-engine":
            guard let value, let engine = SearchEngine(rawValue: value) else { return }
            BrowserSettings.searchEngine = engine
            tab.webView.reload()
        case "choose-downloads":
            chooseDownloadDirectory(for: tab)
        case "show-downloads":
            NSWorkspace.shared.open(BrowserSettings.downloadDirectory)
        case "clear-history":
            confirmSettingsChange(
                title: "Clear browsing history?",
                message: "\(appName) will remove saved addresses and page titles from suggestions.",
                button: "Clear History"
            ) {
                History.shared.clear()
                tab.webView.reload()
            }
        case "clear-website-data":
            confirmSettingsChange(
                title: "Clear all website data?",
                message: "This removes cookies, caches, local storage, and website sign-ins. This cannot be undone.",
                button: "Clear Website Data"
            ) {
                let store = WKWebsiteDataStore.default()
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    tab.webView.reload()
                }
            }
        case "extensions":
            openTab(url: ExtensionCatalog.pageURL)
        case "make-default":
            makeDefaultBrowser(for: tab)
        default:
            break
        }
    }

    private func chooseDownloadDirectory(for tab: Tab) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = BrowserSettings.downloadDirectory
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            BrowserSettings.downloadDirectory = url
            tab.webView.reload()
        }
    }

    private func makeDefaultBrowser(for tab: Tab) {
        Task { @MainActor in
            do {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https")
                tab.webView.reload()
            } catch {
                showSettingsError(error)
            }
        }
    }

    private func confirmSettingsChange(
        title: String, message: String, button: String, action: @escaping () -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }

    private func showSettingsError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    @objc private func runExtensionAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? WKWebExtension.Action,
            let context = action.webExtensionContext
        else { return }
        if let active { context.userGesturePerformed(in: active) }
        context.performAction(for: active)
    }

    @objc private func openExtensionOptions(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? WKWebExtensionContext,
            let url = context.optionsPageURL
        else { return }
        openTab(url: url)
    }

    @objc private func removeExtension(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? WKWebExtensionContext else { return }
        confirmRemoval(of: context)
    }

    private func confirmRemoval(of context: WKWebExtensionContext, completion: (() -> Void)? = nil) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(context.webExtension.displayName ?? "extension")?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                try? WebExtensions.shared.remove(context)
                completion?()
            }
        }
    }

    private func showExtensionError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    private func dismissOmnibox() {
        guard let active, !active.isBlank else { return }
        active.isOmniboxOpen = false
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
        browserMenu.dismiss()
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
        browserMenu.dismiss()
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
        active.webView.pageZoom = zoom
        if isRegisteredWithExtensions {
            WebExtensions.shared.controller.didChangeTabProperties(.zoomFactor, for: active)
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        // AppKit can ask on the second mouse-up, after the clicked control has already changed the strip.
        guard let event = NSApp.currentEvent, event.clickCount >= 2 else { return true }
        return (window as? BrowserWindow)?.firstClickAllowsZoom == true
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

    // MARK: WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { active }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        close()
        completionHandler(nil)
    }
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
    private let browserMenu: BrowserMenuView, find: FindView
    /// Kept from the last windowed layout, because in full screen the titlebar leaves the window.
    private var stripHeight: CGFloat = 52
    /// The traffic lights' frames as the system lays them out, captured before they are first enlarged.
    private var systemLights: [NSRect] = []

    init(strip: TabStripView, content: NSView, omnibox: NSView, browserMenu: BrowserMenuView, find: FindView) {
        (self.strip, self.content, self.omnibox, self.browserMenu, self.find) = (strip, content, omnibox, browserMenu, find)
        super.init(frame: .zero)
        [content, omnibox, strip, browserMenu, find].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Lifts AppKit's native traffic lights 6pt with the strip and spreads their centers to 25pt while
    /// keeping the close button's horizontal position.
    private func placeTrafficLights(of window: NSWindow) {
        let spacing: CGFloat = 25
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        guard buttons.count == 3, let titlebar = buttons[0].superview, !window.styleMask.contains(.fullScreen) else { return }
        if systemLights.isEmpty {
            systemLights = buttons.map(\.frame)
        }

        let closeCenterX = systemLights[0].midX
        for (index, pair) in zip(buttons, systemLights).enumerated() {
            let (button, system) = pair
            let size = system.size
            let centeredY = (titlebar.bounds.height - size.height) / 2
            let frame = NSRect(
                x: closeCenterX + CGFloat(index) * spacing - size.width / 2,
                y: centeredY + (titlebar.isFlipped ? -6 : 6),
                width: size.width,
                height: size.height)
            if button.frame != frame {
                button.frame = frame
                button.setBoundsSize(system.size)
            }
        }
    }

    override func layout() {
        super.layout()
        if let window {
            let titlebarHeight = window.frame.height - window.contentLayoutRect.maxY
            if titlebarHeight > 0 { stripHeight = titlebarHeight }
            placeTrafficLights(of: window)
            // Tabs start right of the traffic lights, or at the edge when full screen hides them.
            let lights = window.standardWindowButton(.zoomButton)
            let lightsEnd = lights.map { $0.convert($0.bounds, to: nil).maxX } ?? 0
            strip.leadingInset = window.styleMask.contains(.fullScreen) ? 12 : lightsEnd + 18
        }
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        content.frame = NSRect(x: 0, y: stripHeight, width: bounds.width, height: bounds.height - stripHeight)
        omnibox.frame = content.frame
        browserMenu.frame = bounds
        find.frame = bounds
        if let window, let close = window.standardWindowButton(.closeButton), !window.styleMask.contains(.fullScreen) {
            let trailingInset = close.convert(close.bounds, to: self).minX
            strip.trailingInset = trailingInset
            browserMenu.trailingInset = trailingInset
            find.trailingInset = trailingInset
        }
    }
}
