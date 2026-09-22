import AppKit
import AuthenticationServices
import WebKit

/// One browser tab. Owns its web view, records visits to history, and tells its window controller
/// whenever title, URL or loading state change. A tab is "blank" until its first navigation.
/// Its `tint` follows what the page shows along its top edge.
/// A pinned tab shows as its site's icon or a monogram in the strip, can't be closed, and comes back
/// on the next launch.
/// A tab nobody has looked at for `sleepAfter` goes to sleep: it gives up its page, and with it the
/// content process holding the page's memory, and brings the page back when it is next selected.
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate, WKWebExtensionTab {
    /// Replaced by a fresh, idle one while the tab sleeps; see `sleepIfIdle`.
    private(set) var webView: WKWebView
    weak var owner: WindowController?
    /// The opening tab, retained weakly and exposed only while both tabs share an ordinary window.
    weak var opener: Tab?
    private(set) var isBlank: Bool
    /// Text left unfinished in this tab's address field. The window reuses one field across tabs.
    var omniboxDraft = ""
    /// The address field exactly as it was when this tab was last switched away from; see `Omnibox.Snapshot`.
    var omniboxSnapshot: Omnibox.Snapshot?
    /// Whether this tab should show the address field when selected.
    var isOmniboxOpen: Bool
    private var observations: [NSKeyValueObservation] = []
    private var authenticationRequest: ASWebAuthenticationSessionRequest?
    private var permissionOrigins: [SitePermissions.Kind: Set<String>] = [:]
    private var failedProtectedRequest: URLRequest?
    private var requestedURL: URL?
    private var committedURL: URL?
    private var navigationRevision = 0
    private var appliedCookieBlock: Bool?
    var temporarySitePolicies: [String: SitePolicy.Decision] = [:]
    private var visitGrants: Set<String> = []
    var groupName: String?
    var isNewTabOverride = false
    private(set) var hasFormEdits = false
    func markEdited() { hasFormEdits = true }
    private var zoomOrigin: String?
    private var privateZooms: [String: Double] = [:]
    var privateSecurityModes: [String: WebSecurityMode] = [:]
    func securityMode(at url: URL) -> WebSecurityMode {
        if !recordsActivity, let origin = BrowsingSecurity.origin(url), let mode = privateSecurityModes[origin] { return mode }
        return WebSecurityMode.mode(for: url)
    }

    /// Applies preferences that WebKit supports changing without replacing the page.
    func refreshPreferences() {
        webView.configuration.preferences.isFraudulentWebsiteWarningEnabled =
            UserDefaults.standard.object(forKey: "FraudWarnings") as? Bool ?? true
        webView.configuration.preferences.tabFocusesLinks = UserDefaults.standard.bool(forKey: "TabFocusesLinks")
        webView.configuration.preferences.minimumFontSize = AddressInput.isWeb(url) ? Settings.minimumFontSize : 0
        webView.configuration.websiteDataStore.httpCookieStore.setCookiePolicy(
            UserDefaults.standard.bool(forKey: "BlockCookies") ? .disallow : .allow
        ) {}
    }

    func setUserZoom(_ factor: Double) {
        let factor = min(5, max(0.25, factor))
        webView.pageZoom = factor
        guard let url, let origin = BrowsingSecurity.origin(url) else { return }
        if recordsActivity {
            var zooms = Settings.siteZooms
            zooms[origin] = factor
            UserDefaults.standard.set(zooms, forKey: "SiteZooms")
        } else {
            privateZooms[origin] = factor
        }
    }

    /// Applies a removed site zoom to open pages, preserving private tabs' temporary overrides.
    func resetSavedZoom(for origin: String) {
        guard let url, BrowsingSecurity.origin(url) == origin else { return }
        if recordsActivity || privateZooms[origin] == nil { webView.pageZoom = Double(Settings.defaultZoom) / 100 }
    }

    func resetPermissions() {
        temporarySitePolicies.removeAll()
        visitGrants.removeAll()
        webView.setCameraCaptureState(.none)
        webView.setMicrophoneCaptureState(.none)
        if permissionOrigins[.location]?.isEmpty == false { webView.reload() }
        permissionOrigins.removeAll()
    }

    /// Private tabs keep explicit choices in memory and ask again before using persistent device grants.
    func policy(_ feature: SitePolicy.Feature, at url: URL) -> SitePolicy.Decision {
        if let origin = BrowsingSecurity.origin(url), let value = temporarySitePolicies[feature.rawValue + origin] { return value }
        let value = SitePolicy.decision(feature, at: url)
        if !recordsActivity, [.camera, .microphone, .location].contains(feature), value == .allow { return .ask }
        return value
    }

    /// One-visit device grants are never persisted and expire when the tab leaves that origin.
    func allowForVisit(_ feature: SitePolicy.Feature, at url: URL) {
        guard let origin = BrowsingSecurity.origin(url) else { return }
        let key = feature.rawValue + origin
        temporarySitePolicies[key] = .allow
        visitGrants.insert(key)
    }

    func clearTemporaryPolicy(_ feature: SitePolicy.Feature, at url: URL) {
        guard let origin = BrowsingSecurity.origin(url) else { return }
        let key = feature.rawValue + origin
        temporarySitePolicies.removeValue(forKey: key)
        visitGrants.remove(key)
    }

    /// Device blocks take effect immediately; content policies apply on the next page navigation.
    func applyPolicyChanges(changed feature: SitePolicy.Feature? = nil, at changedOrigin: String? = nil) {
        if let url, AddressInput.isWeb(url) { webView.setAllMediaPlaybackSuspended(policy(.media, at: url) == .block) }
        for kind in SitePermissions.Kind.allCases {
            if let feature, feature.rawValue != kind.rawValue { continue }
            for origin in permissionOrigins[kind] ?? [] {
                if let changedOrigin, origin != changedOrigin { continue }
                guard let url = URL(string: origin) else { continue }
                let key = SitePolicy.Feature(rawValue: kind.rawValue)!
                let decision = policy(key, at: url)
                let inheritsDefault = SitePolicy.entries(key)[origin] == nil && temporarySitePolicies[key.rawValue + origin] == nil
                if decision == .block || (feature != nil && (changedOrigin != nil || inheritsDefault) && decision != .allow) {
                    revokePermission(kind, at: url)
                }
            }
        }
    }

    /// The address this tab was pinned at, restored on launch; nil for ordinary tabs.
    var pinnedURL: URL?
    var isPinned: Bool { pinnedURL != nil }
    /// A restored pinned tab waits here until it is first selected, so launch stays cheap.
    private var pendingURL: URL?

    /// How long a tab stays hidden before it may sleep.
    static let sleepAfter: TimeInterval = 30 * 60
    /// When the tab was last hidden; nil while it shows. Kept by the window.
    var hiddenSince: Date?
    /// What a sleeping tab keeps of its page: enough for the strip, and the state that brings it back.
    private var asleep: (title: String, url: URL, state: Any?)?
    /// A page opened by another page's script stays awake: its opener may be waiting to hear from it.
    private let isScriptOpened: Bool
    /// So does a page that opened one, such as a sign-in window that reports back to it.
    private var hasOpenedTab = false
    /// Whether the tab has given up its page and is waiting to restore it.
    var isAsleep: Bool { asleep != nil }
    /// The page's address, also while it sleeps.
    var url: URL? { asleep?.url ?? pendingURL ?? requestedURL ?? webView.url }

    /// The site's icon for the strip: the one remembered for the host once a page commits, then the
    /// one the page declares once its DOM is ready. Nil when unknown or while favicons are turned off.
    private(set) var favicon: NSImage?
    private var faviconHost: String?

    /// Set while a reload is being hidden; see `reload`.
    private var reloadHold: ReloadHold?

    /// What `tint` last was, shown while a new page has yet to report; nil after a blank tab.
    private var lastTint: NSColor?

    /// The host of the page last committed, to tell moving within a site from leaving it.
    private var committedHost: String?

    /// Follows what the page shows along its top edge, for `tint`.
    private(set) lazy var pageTint = PageTint(
        isLoading: { [weak self] in self?.webView.isLoading ?? false },
        isShown: { [weak self] in self?.webView.window != nil && (self?.webView.bounds.width ?? 0) > 0 },
        snapshot: { [weak self] done in
            guard let webView = self?.webView else { return done(nil) }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: 2)
            configuration.afterScreenUpdates = false
            webView.takeSnapshot(with: configuration) { image, _ in
                done(image?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(DominantColor.of))
            }
        },
        onChange: { [weak self] in self.map { $0.owner?.tabTintDidChange($0) } })

    /// Pass the configuration WebKit hands to `createWebViewWith` for pages opened by script;
    /// such tabs are never blank because WebKit starts their load itself.
    init(configuration: WKWebViewConfiguration? = nil, scriptOpened: Bool = false) {
        isBlank = configuration == nil
        isOmniboxOpen = configuration == nil
        isScriptOpened = scriptOpened
        webView = Tab.makeWebView(configuration ?? Tab.configuration())
        super.init()
        attach()
    }

    private static func makeWebView(_ configuration: WKWebViewConfiguration) -> WKWebView {
        if !configuration.websiteDataStore.isPersistent {
            configuration.webExtensionController = nil
        } else if configuration.webExtensionController == nil {
            configuration.webExtensionController = WebExtensions.shared.controller
        }
        // Script-opened windows can inherit their opener's controller. Site policies must remain tab-local.
        let previousScripts = configuration.userContentController.userScripts
        let content = WKUserContentController()
        TintRouter.install(in: content)
        HoveredLink.install(in: content)
        Editing.install(in: content)
        let ownSources = Set(content.userScripts.map(\.source))
        for script in previousScripts where !ownSources.contains(script.source) { content.addUserScript(script) }
        configuration.userContentController = content
        configuration.preferences = WKPreferences()
        configuration.preferences.isElementFullscreenEnabled = true
        BrowsingSecurity.configure(configuration)
        TrackerProtection.shared.installIfReady(in: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.pageZoom = Double(Settings.defaultZoom) / 100
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        #if DEBUG
            webView.isInspectable = true
        #endif
        return webView
    }

    /// Makes this tab the delegate and observer of its current web view.
    private func attach() {
        Editing.shared.bind(webView, to: self)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.titleChanged() },
            webView.observe(\.url) { [weak self] _, _ in self?.urlChanged() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.changed([.loading]) },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.changed() },
            webView.observe(\.underPageBackgroundColor) { [weak self] _, _ in self?.changed() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.changed() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.changed() },
        ]
    }

    /// A pinned tab restored from the last session; it loads `url` when first selected.
    convenience init(pinnedAt url: URL) {
        self.init()
        isBlank = false
        isOmniboxOpen = false
        pinnedURL = url
        pendingURL = url
        showRememberedFavicon(for: url)
    }

    var title: String {
        if let asleep { return asleep.title }
        if let title = webView.title, !title.isEmpty { return title }
        if let url = webView.url ?? pinnedURL, url.scheme != "about" { return AddressInput.display(for: url) }
        return "New Tab"
    }

    /// The letter a pinned tab shows when it has no icon: the first of its site's name.
    var monogram: String {
        let host = (url ?? pinnedURL)?.host ?? ""
        return AddressInput.stripped(host).prefix(1).uppercased()
    }

    /// Brings the icon in line with the favicons setting after it changes.
    func faviconsSettingChanged() {
        (favicon, faviconHost) = (nil, nil)
        showRememberedFavicon(for: url ?? pinnedURL)
        if webView.url == committedURL { loadFavicon() }
    }

    /// Shows the icon remembered for the address's host. Pages on one host can have icons of their
    /// own, so moving within a host keeps the current icon until the new page declares its own.
    private func showRememberedFavicon(for url: URL?) {
        let host =
            recordsActivity && Settings.historyDays != -1 && Settings.showsFavicons && AddressInput.isWeb(url)
            ? url?.host?.lowercased() : nil
        guard host != faviconHost else { return }
        faviconHost = host
        favicon = host == nil ? nil : Favicons.shared.icon(for: url)
    }

    /// Starts discovery at commit, before slow page resources finish. Results belong to this exact
    /// navigation and web view, even when another page on the same host replaces it.
    private func loadFavicon() {
        guard recordsActivity, Settings.historyDays != -1, Settings.showsFavicons, let page = webView.url, AddressInput.isWeb(page) else {
            return
        }
        let asked = webView
        let revision = navigationRevision
        Task { @MainActor [weak self] in
            let isCurrent = { [weak self] in
                guard let self else { return false }
                return self.webView === asked && self.navigationRevision == revision && asked.url == page
                    && self.recordsActivity && Settings.showsFavicons && Settings.historyDays != -1
            }
            guard isCurrent(), let image = await Favicons.shared.load(in: asked, page: page, isCurrent: isCurrent),
                isCurrent(), let self, self.favicon !== image
            else { return }
            self.favicon = image
            self.changed()
        }
    }

    /// Starts what a tab put off until it is looked at: a restored pin's first load, or waking up.
    func loadIfPending() {
        if let url = pendingURL {
            pendingURL = nil
            load(url)
        } else if let asleep {
            self.asleep = nil
            if asleep.state != nil { webView.interactionState = asleep.state } else { webView.load(URLRequest(url: asleep.url)) }
        }
    }

    /// A fallback check for main-frame fields, including autofill. Editing also tracks input in every frame.
    private static let hasEdits = """
        return [...document.querySelectorAll('input, textarea')].some(field =>
                field.type !== 'hidden' && typeof field.defaultValue === 'string' && field.value !== field.defaultValue)
            || document.activeElement?.isContentEditable === true
        """

    /// What rules sleeping out without asking the page. Each case is one reason a tab keeps its page;
    /// `sleepBlocker` returns the first that applies, which is what the sleep channel reports and what
    /// the tests pin. Adding a rule means adding a case, so no rule is nameless.
    enum SleepBlocker: String {
        case alreadyAsleep
        case editedForm
        case neverSleepSite
        case pinned
        case openedByScript
        case openedATab
        case blank
        case loadPending
        case reloading
        case signingIn
        case onScreen
        case hiddenTooRecently
        case loading
        case fullScreen
        case capturing
        case notTheSharedSession
        case notAWebPage
    }

    /// The first reason this tab keeps its page, or nil when nothing here stands in the way. The page
    /// is still asked about playback and typed text afterwards; see `sleepIfIdle`.
    func sleepBlocker(hiddenFor minimum: TimeInterval) -> SleepBlocker? {
        if asleep != nil { return .alreadyAsleep }
        if hasFormEdits { return .editedForm }
        if let url, let origin = BrowsingSecurity.origin(url),
            (UserDefaults.standard.stringArray(forKey: "NeverSleepSites") ?? []).contains(origin)
        {
            return .neverSleepSite
        }
        if isPinned { return .pinned }
        if isScriptOpened { return .openedByScript }
        if hasOpenedTab { return .openedATab }
        if isBlank { return .blank }
        if pendingURL != nil { return .loadPending }
        if reloadHold != nil { return .reloading }
        if authenticationRequest != nil { return .signingIn }
        if webView.superview != nil { return .onScreen }
        guard let hiddenSince, Date().timeIntervalSince(hiddenSince) >= minimum else { return .hiddenTooRecently }
        if webView.isLoading { return .loading }
        if webView.fullscreenState != .notInFullscreen { return .fullScreen }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return .capturing }
        if !webView.configuration.websiteDataStore.isPersistent { return .notTheSharedSession }
        if !AddressInput.isWeb(webView.url) { return .notAWebPage }
        return nil
    }

    /// Puts the tab to sleep if it has been hidden for `minimum` and nothing would be lost: see
    /// `sleepBlocker`, and it must not be playing anything nor hold typed text. The page's address, history
    /// and scroll position come back on waking; what a page keeps only in memory does not. The old web
    /// view is let go, which ends its content process, and an idle one, which has no process, takes
    /// its place.
    func sleepIfIdle(hiddenFor minimum: TimeInterval = Tab.sleepAfter) {
        if let blocker = sleepBlocker(hiddenFor: minimum) {
            return Log.write(.sleep, "staying awake: \(blocker.rawValue)")
        }
        let asked = webView
        asked.requestMediaPlaybackState { [weak self] playback in
            guard playback != .playing else { return Log.write(.sleep, "staying awake: playing") }
            asked.callAsyncJavaScript(Self.hasEdits, arguments: [:], in: nil, in: .defaultClient) { result in
                guard let self, asked === self.webView, (try? result.get()) as? Bool == false,
                    self.sleepBlocker(hiddenFor: minimum) == nil, let url = asked.url
                else { return Log.write(.sleep, "staying awake: typed text, or a rule changed while asking") }
                Log.write(
                    .sleep,
                    "sleeping after \(Int(minimum))s hidden, keeping \(asked.interactionState == nil ? "the address" : "the session")")
                self.asleep = (self.title, url, asked.interactionState)
                self.observations = []
                asked.navigationDelegate = nil
                asked.uiDelegate = nil
                self.webView = Tab.makeWebView(Tab.configuration())
                self.webView.pageZoom = asked.pageZoom
                self.attach()
                self.changed()
            }
        }
    }

    /// The color the window chrome takes on for this tab: whatever the page shows along its top edge
    /// right now, so the strip reads as a continuation of it, a hero image or sticky header included.
    /// Until the first sample of a page arrives it is the page's background color. Deliberately never the
    /// declared theme color, which sites often set to a brand color that matches nothing under the strip.
    /// Nil while the tab is blank; the window uses the native address view's background instead.
    var tint: NSColor? {
        if let reloadHold { return reloadHold.tint }
        if isBlank { return nil }
        // A page that has only just committed has not said what it shows; stay as we were.
        if pageTint.isWaiting { return lastTint }
        lastTint = pageTint.color ?? webView.underPageBackgroundColor?.withAlphaComponent(1)
        return lastTint
    }

    /// The fade the page's own header is making to `tint`, for the strip to make with it.
    var tintFade: PageTint.Fade? { reloadHold == nil && pageTint.isFromStyles ? pageTint.fade : nil }

    /// Reloads the page so that nothing appears to move, and the strip keeps its color meanwhile; see
    /// `ReloadHold`. A tab that is hidden or has no page reloads plainly.
    func reload() {
        if let request = failedProtectedRequest {
            failedProtectedRequest = nil
            webView.load(request)
            return
        }
        guard reloadHold == nil, !isBlank, webView.url != nil, webView.window != nil else { return _ = webView.reload() }
        let release = { [weak self] in
            guard let self else { return }
            reloadHold = nil
            owner?.tabDidChange(self)
        }
        ReloadHold.begin(in: webView, tint: tint, onEnd: release) { [weak self] hold in
            self?.reloadHold = hold
            self?.webView.reload()
        }
    }

    /// Restores an ordinary closed tab's navigation state without opening a new-tab override first.
    func restore(url: URL, state: Any?) {
        requestedURL = url
        guard let state else { return load(url) }
        isBlank = false
        isOmniboxOpen = false
        omniboxDraft = ""
        omniboxSnapshot = nil
        webView.interactionState = state
        changed()
    }

    /// Loads a new address and clears the address-field draft.
    func load(_ url: URL) { loadRequest(URLRequest(url: url)) }

    /// Privileged extension pages use a bound WebKit configuration. Leaving one creates an ordinary view.
    private func loadRequest(_ request: URLRequest) {
        guard let url = request.url else { return }
        if self.url?.scheme == "webkit-extension", url.scheme != "webkit-extension" {
            let old = webView
            let configuration = Tab.configuration(ephemeral: !recordsActivity)
            configuration.websiteDataStore = old.configuration.websiteDataStore
            observations.removeAll()
            old.navigationDelegate = nil
            old.uiDelegate = nil
            old.stopLoading()
            webView = Self.makeWebView(configuration)
            zoomOrigin = nil
            appliedCookieBlock = nil
            attach()
            isNewTabOverride = false
            owner?.replaceView(for: self, previous: old)
        }
        requestedURL = url
        if webView.url == nil { webView.alphaValue = 0 }
        isBlank = false
        isOmniboxOpen = false
        omniboxDraft = ""
        omniboxSnapshot = nil
        failedProtectedRequest = nil
        webView.load(request)
    }

    /// Loads one authentication request, including headers that apply only to its first navigation.
    func loadAuthentication(_ request: ASWebAuthenticationSessionRequest) {
        authenticationRequest = request
        isBlank = false
        isOmniboxOpen = false
        var urlRequest = URLRequest(url: request.url)
        request.additionalHeaderFields?.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
        failedProtectedRequest = nil
        webView.load(urlRequest)
    }

    private func showProtectionError() {
        showError(
            NSError(
                domain: "BrowserProtection", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Tracker protection could not start. Reload to try again."
                ]))
    }

    var authenticationRequestID: UUID? { authenticationRequest?.uuid }

    /// Cancels an unfinished authentication request because its tab was closed by the user.
    func cancelAuthentication() {
        guard let request = authenticationRequest else { return }
        authenticationRequest = nil
        request.cancelWithError(
            NSError(
                domain: ASWebAuthenticationSessionError.errorDomain,
                code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue))
    }

    /// Drops a request canceled by its originating app without sending a second cancellation.
    func authenticationWasCancelled() {
        authenticationRequest = nil
    }

    private func reveal() {
        guard webView.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            webView.animator().alphaValue = 1
        }
    }

    /// Creates a browser configuration, isolating storage and extensions for ephemeral sign-in sessions.
    static func configuration(ephemeral: Bool = false) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if ephemeral {
            configuration.websiteDataStore = .nonPersistent()
        } else {
            WebExtensions.shared.configure(configuration)
        }
        AeroPages.shared.configure(configuration)
        if UserDefaults.standard.bool(forKey: "BlockCookies") {
            configuration.websiteDataStore.httpCookieStore.setCookiePolicy(.disallow) {}
        }
        // Safari's version has matched the system's since 26; before that it ran three ahead of macOS.
        let system = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(system >= 26 ? system : system + 3).0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    private func changed(_ extensionProperties: WKWebExtension.TabChangedProperties = []) {
        owner?.tabDidChange(self, extensionProperties: extensionProperties)
    }

    /// A new address without a new page is a client-side route change: the page under the strip may
    /// be a different one, so the page's script is asked to read it now rather than when it next notices.
    private func urlChanged() {
        if let url = webView.url { requestedURL = url }
        if !webView.isLoading {
            webView.evaluateJavaScript("globalThis.aeroReadTint?.()", in: nil, in: .defaultClient) { _ in }
        }
        changed([.URL])
    }

    private func titleChanged() {
        if recordsActivity, let url = webView.url, let title = webView.title, !title.isEmpty {
            History.shared.setTitle(title, for: url)
        }
        changed([.title])
    }

    private func showError(_ error: Error) {
        reveal()
        reloadHold?.end()
        let error = error as NSError
        let cancelled = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        let interruptedByPolicy = error.domain == "WebKitErrorDomain" && error.code == 102
        if cancelled || interruptedByPolicy { return }

        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        webView.loadHTMLString(
            """
            <meta name="color-scheme" content="light dark">
            <body style="font: 13px -apple-system; color: gray; display: grid; place-items: center; height: 100vh; margin: 0">
            <p>\(message)</p>
            """, baseURL: failedURL)
    }

    // MARK: WKNavigationDelegate

    /// Ephemeral WebKit storage also excludes the native history and icon caches.
    var recordsActivity: Bool { webView.configuration.websiteDataStore.isPersistent }

    /// HTTPS-first for the public web; explicit HTTP remains usable for local servers and LAN devices.
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.preferredHTTPSNavigationPolicy = BrowsingSecurity.httpsPolicy(for: action.request.url)
        GlobalPrivacyControl.apply(to: preferences)
        if let url = action.request.url, AddressInput.isWeb(url) {
            preferences.allowsContentJavaScript = policy(.javaScript, at: url) != .block
            if action.targetFrame?.isMainFrame == true {
                securityMode(at: url).apply(to: preferences)
                webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = policy(.popups, at: url) == .allow
                webView.configuration.preferences.minimumFontSize = Settings.minimumFontSize
                let origin = BrowsingSecurity.origin(url)
                if zoomOrigin != origin {
                    zoomOrigin = origin
                    let saved = origin.flatMap { privateZooms[$0] ?? Settings.siteZooms[$0] }
                    webView.pageZoom = min(5, max(0.25, saved ?? Double(Settings.defaultZoom) / 100))
                }
            }
        } else if action.targetFrame?.isMainFrame == true, action.request.url?.path.hasPrefix("/action/") != true {
            if ["aero", "webkit-extension"].contains(action.request.url?.scheme ?? "") { preferences.allowsContentJavaScript = true }
            if zoomOrigin != "internal" { webView.pageZoom = 1 }
            zoomOrigin = "internal"
            webView.configuration.preferences.minimumFontSize = 0
        }
        self.webView(webView, decidePolicyFor: action) { decisionHandler($0, preferences) }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let isWeb = AddressInput.isWeb(action.request.url)
        let internalPage = action.request.url?.scheme == "aero" && action.request.url?.path.hasPrefix("/action/") != true
        guard isWeb || internalPage else {
            if action.targetFrame?.isMainFrame == true, action.request.url?.path.hasPrefix("/action/") != true {
                navigationRevision += 1
                ImageBlocking.remove(from: webView.configuration.userContentController)
            }
            return decideNavigation(webView, action: action, decisionHandler: decisionHandler)
        }
        let mainFrame = action.targetFrame?.isMainFrame == true
        if mainFrame { navigationRevision += 1 }
        let revision = navigationRevision
        Task { @MainActor in
            do {
                let blockCookies = UserDefaults.standard.bool(forKey: "BlockCookies")
                if mainFrame, appliedCookieBlock != blockCookies {
                    await webView.configuration.websiteDataStore.httpCookieStore.setCookiePolicy(blockCookies ? .disallow : .allow)
                    appliedCookieBlock = blockCookies
                }
                if isWeb { try await TrackerProtection.shared.prepare(webView.configuration.userContentController) }
                if mainFrame, let url = action.request.url {
                    let images = isWeb && policy(.images, at: url) == .block ? try await ImageBlocking.list() : nil
                    guard revision == navigationRevision else { return decisionHandler(.cancel) }
                    ImageBlocking.remove(from: webView.configuration.userContentController)
                    if let images { webView.configuration.userContentController.add(images) }
                }
                decideNavigation(webView, action: action, decisionHandler: decisionHandler)
            } catch {
                decisionHandler(.cancel)
                failedProtectedRequest = action.request
                showProtectionError()
            }
        }
    }

    /// Internal commands require the initiating frame, destination and displayed page to agree.
    private func decideNavigation(
        _ webView: WKWebView, action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        if action.targetFrame?.isMainFrame == true, webView.url?.scheme == "webkit-extension", AddressInput.isWeb(url) {
            decisionHandler(.cancel)
            if isNewTabOverride { loadRequest(action.request) } else { owner?.openTab(url: url) }
            return
        }
        if action.targetFrame?.isMainFrame != false, completeAuthenticationIfNeeded(with: url) {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "aero", url.path.hasPrefix("/action/") {
            if BrowsingSecurity.allowsInternalAction(
                url, source: action.sourceFrame.request.url,
                isMainFrame: action.sourceFrame.isMainFrame, targetsMainFrame: action.targetFrame?.isMainFrame == true),
                action.sourceFrame.securityOrigin.protocol == "aero", action.sourceFrame.securityOrigin.host == url.host,
                webView.url?.host == url.host, webView.url?.scheme == "aero"
            {
                switch url.host {
                case "extensions": owner?.handleExtensionCatalogAction(url, from: self)
                case "settings": owner?.handleSettingsAction(url, from: self)
                case "history", "bookmarks", "downloads", "site-data": owner?.handleLibraryAction(url, from: self)
                default: break
                }
            }
            return decisionHandler(.cancel)
        }
        if url.scheme == "aero", action.targetFrame?.isMainFrame != true {
            return decisionHandler(.cancel)
        }
        if action.shouldPerformDownload { return decisionHandler(.download) }
        // External apps require a top-level link and native confirmation, never a script redirect.
        if !["http", "https", "aero", "about", "blob", "data", "file", "javascript", "webkit-extension"].contains(
            url.scheme?.lowercased() ?? "")
        {
            decisionHandler(.cancel)
            guard action.navigationType == .linkActivated, action.sourceFrame.isMainFrame, let window = webView.window else { return }
            let alert = NSAlert()
            alert.messageText = "Open another app?"
            let origin = action.sourceFrame.securityOrigin
            alert.informativeText =
                "\(BrowsingSecurity.label(scheme: origin.protocol, host: origin.host, port: origin.port)) wants to open a \(url.scheme ?? "") link."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open App")
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
            }
            return
        }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) {
            let configuration = recordsActivity ? nil : webView.configuration
            owner?.openTab(url: url, configuration: configuration, inBackground: true)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    private func completeAuthenticationIfNeeded(with url: URL) -> Bool {
        guard let request = authenticationRequest else { return false }
        guard request.callback?.matchesURL(url) == true else { return false }
        authenticationRequest = nil
        request.complete(withCallbackURL: url)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            owner?.close(self)
        }
        return true
    }

    // MARK: WKWebExtensionTab

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        recordsActivity && owner?.isPrivate == false ? owner : nil
    }
    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard recordsActivity, let owner, !owner.isPrivate, let opener, opener.recordsActivity,
            opener.owner === owner, owner.tabs.contains(where: { $0 === opener })
        else { return nil }
        return opener
    }

    /// Changes the opener only to another public tab in the same window.
    func setParentTab(
        _ parent: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void
    ) {
        guard recordsActivity, let owner, !owner.isPrivate,
            parent == nil
                || (parent as? Tab).map({ $0 !== self && $0.recordsActivity && $0.owner === owner && owner.tabs.contains($0) }) == true
        else { return completionHandler(NSError(domain: "BrowserExtension", code: 1)) }
        opener = parent as? Tab
        completionHandler(nil)
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard recordsActivity, owner?.isPrivate == false else { return NSNotFound }
        return owner?.tabs.filter(\.recordsActivity).firstIndex { $0 === self } ?? NSNotFound
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }
    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard zoomFactor.isFinite, zoomFactor > 0 else { return completionHandler(NSError(domain: "BrowserExtension", code: 2)) }
        setUserZoom(zoomFactor)
        changed([.zoomFactor])
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        owner?.select(self)
        owner?.window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if isPinned { owner?.setPinned(false, tab: self) }
        owner?.close(self)
        completionHandler(nil)
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        guard recordsActivity, let owner, !owner.isPrivate else {
            return completionHandler(
                nil, NSError(domain: "BrowserExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: "The tab has no window."]))
        }
        WebExtensions.shared.openTab(
            using: configuration, for: context, fallbackWindow: owner, fallbackURL: url, completionHandler: completionHandler)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if selected { owner?.select(self) }
        completionHandler(nil)
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        owner?.setPinned(pinned, tab: self)
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        acceptDownload(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        acceptDownload(download)
    }

    private func acceptDownload(_ download: WKDownload) {
        guard let owner else { download.cancel { _ in }; return }
        let decision = url.map { policy(.downloads, at: $0) } ?? .ask
        if decision == .block { download.cancel { _ in }; return }
        if decision == .ask, let window = owner.window {
            let alert = NSAlert()
            alert.messageText = "Allow this download?"
            alert.informativeText = "\(url?.host ?? "This page") wants to download a file."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    owner.downloads.accept(download, recordsActivity: self.recordsActivity)
                } else {
                    download.cancel { _ in }
                }
            }
        } else {
            owner.downloads.accept(download, recordsActivity: recordsActivity)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasFormEdits = false
        committedURL = webView.url
        let origin = committedURL.flatMap(BrowsingSecurity.origin)
        for key in visitGrants where origin.map({ !key.hasSuffix($0) }) ?? true {
            temporarySitePolicies.removeValue(forKey: key)
            visitGrants.remove(key)
        }
        if let url = webView.url, AddressInput.isWeb(url) { webView.setAllMediaPlaybackSuspended(policy(.media, at: url) == .block) }
        permissionOrigins.removeAll()
        if recordsActivity, let url = webView.url { History.shared.visit(url) }
        owner?.tabDidLeavePage(self)
        showRememberedFavicon(for: webView.url)
        loadFavicon()
        let host = webView.url?.host
        pageTint.reset(holding: host != nil && host == committedHost ? 2 : 0.25)
        committedHost = host
        reveal()
        reloadHold?.pageCommitted()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        hasOpenedTab = true
        return owner?.openTab(configuration: configuration, scriptOpened: true, opener: self).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.close(self)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        runPanel(message: message, frame: frame, buttons: ["OK"]) { _, _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        runPanel(message: message, frame: frame, buttons: ["OK", "Cancel"]) { confirmed, _ in completionHandler(confirmed) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void
    ) {
        runPanel(message: prompt, frame: frame, buttons: ["OK", "Cancel"], input: defaultText ?? "") { confirmed, text in
            completionHandler(confirmed ? text : nil)
        }
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { response in completionHandler(response == .OK ? panel.urls : nil) }
    }

    /// Enforces per-origin denials before WebKit's per-origin system approval prompt.
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard let url = URL(string: BrowsingSecurity.label(scheme: origin.protocol, host: origin.host, port: origin.port)) else {
            return decisionHandler(.deny)
        }
        let camera = type == .camera || type == .cameraAndMicrophone
        let microphone = type == .microphone || type == .cameraAndMicrophone
        let topURL = committedURL ?? url
        let cameraDecision = SitePolicy.combined(policy(.camera, at: topURL), policy(.camera, at: url))
        let microphoneDecision = SitePolicy.combined(policy(.microphone, at: topURL), policy(.microphone, at: url))
        let denied = (camera && cameraDecision == .block) || (microphone && microphoneDecision == .block)
        if !denied, let key = BrowsingSecurity.origin(url) {
            if camera { permissionOrigins[.camera, default: []].insert(key) }
            if microphone { permissionOrigins[.microphone, default: []].insert(key) }
            if let top = BrowsingSecurity.origin(topURL) {
                if camera { permissionOrigins[.camera, default: []].insert(top) }
                if microphone { permissionOrigins[.microphone, default: []].insert(top) }
            }
        }
        let allowed = (!camera || cameraDecision == .allow) && (!microphone || microphoneDecision == .allow)
        decisionHandler(denied ? .deny : allowed ? .grant : .prompt)
    }

    /// Enforces location denials before WebKit's system prompt on macOS 27 and later.
    @available(macOS 27.0, *)
    @objc(webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard let url = URL(string: BrowsingSecurity.label(scheme: origin.protocol, host: origin.host, port: origin.port)) else {
            return decisionHandler(.deny)
        }
        let policy = SitePolicy.combined(policy(.location, at: committedURL ?? url), policy(.location, at: url))
        let denied = policy == .block
        if !denied, let key = BrowsingSecurity.origin(url) { permissionOrigins[.location, default: []].insert(key) }
        if !denied, let top = committedURL.flatMap(BrowsingSecurity.origin) { permissionOrigins[.location, default: []].insert(top) }
        decisionHandler(denied ? .deny : policy == .allow ? .grant : .prompt)
    }

    /// Stops an origin's existing access, including embedded frames, without interrupting unrelated tabs.
    func revokePermission(_ kind: SitePermissions.Kind, at url: URL) {
        guard let key = BrowsingSecurity.origin(url), permissionOrigins[kind]?.contains(key) == true else { return }
        switch kind {
        case .camera: webView.setCameraCaptureState(.none)
        case .microphone: webView.setMicrophoneCaptureState(.none)
        case .location: webView.reload()
        }
    }

    /// Labels dialogs with the initiating frame's origin so embedded pages cannot impersonate the host.
    /// `done` gets whether the first button was chosen and the input text, empty when `input` is nil.
    private func runPanel(
        message: String, frame: WKFrameInfo, buttons: [String], input: String? = nil,
        done: @escaping (Bool, String) -> Void
    ) {
        guard let window = webView.window else { return done(false, "") }
        let alert = NSAlert()
        let origin = frame.securityOrigin
        alert.messageText = BrowsingSecurity.label(scheme: origin.protocol, host: origin.host, port: origin.port)
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        let field = input.map { text -> NSTextField in
            let field = NSTextField(string: text)
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
            alert.accessoryView = field
            return field
        }
        alert.beginSheetModal(for: window) { response in
            done(response == .alertFirstButtonReturn, field?.stringValue ?? "")
        }
    }
}
