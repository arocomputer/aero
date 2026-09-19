import AppKit
import AuthenticationServices
import WebKit

/// One browser tab. Owns its web view, records visits to history, and tells its window controller
/// whenever title, URL or loading state change. A tab is "blank" until its first navigation.
/// Its `chromeColor` follows what the page shows along its top edge.
/// A pinned tab shows as a monogram in the strip, can't be closed, and comes back on the next launch.
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate, WKWebExtensionTab {
    let webView: WKWebView
    weak var owner: BrowserWindowController?
    private(set) var isBlank: Bool
    /// Text left unfinished in this tab's address field. The window reuses one field across tabs.
    var omniboxDraft = ""
    /// Whether this tab should show the address field when selected.
    var isOmniboxOpen: Bool
    private var observations: [NSKeyValueObservation] = []
    private var authenticationRequest: ASWebAuthenticationSessionRequest?

    /// The address this tab was pinned at, restored on launch; nil for ordinary tabs.
    var pinnedURL: URL?
    var isPinned: Bool { pinnedURL != nil }
    /// A restored pinned tab waits here until it is first selected, so launch stays cheap.
    private var pendingURL: URL?

    /// Set while a reload is being hidden; see `reload`.
    private var reloadHold: ReloadHold?

    /// Follows what the page shows along its top edge, for `chromeColor`.
    private(set) lazy var edge = PageEdge(
        isLoading: { [weak webView] in webView?.isLoading ?? false },
        isShown: { [weak webView] in webView?.window != nil && (webView?.bounds.width ?? 0) > 0 },
        snapshot: { [weak webView] done in
            guard let webView else { return done(nil) }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: 2)
            configuration.afterScreenUpdates = false
            webView.takeSnapshot(with: configuration) { image, _ in
                done(image?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(EdgeColor.dominant))
            }
        },
        onChange: { [weak self] in self.map { $0.owner?.tabChromeDidChange($0) } })

    /// Pass the configuration WebKit hands to `createWebViewWith` for pages opened by script;
    /// such tabs are never blank because WebKit starts their load itself.
    init(configuration: WKWebViewConfiguration? = nil) {
        isBlank = configuration == nil
        isOmniboxOpen = configuration == nil
        webView = WKWebView(frame: .zero, configuration: configuration ?? Tab.configuration())
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        #if DEBUG
            webView.isInspectable = true
        #endif
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self

        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.titleChanged() },
            webView.observe(\.url) { [weak self] _, _ in self?.changed([.URL]) },
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
    }

    var title: String {
        if let title = webView.title, !title.isEmpty { return title }
        if let url = webView.url ?? pinnedURL, url.scheme != "about" { return AddressInput.display(for: url) }
        return "New Tab"
    }

    /// The letter a pinned tab shows: the first of its site's name.
    var monogram: String {
        let host = (webView.url ?? pinnedURL)?.host ?? ""
        return AddressInput.stripped(host).prefix(1).uppercased()
    }

    func loadIfPending() {
        if let url = pendingURL {
            pendingURL = nil
            load(url)
        }
    }

    /// The color the window chrome takes on for this tab: whatever the page shows along its top edge
    /// right now, so the strip reads as a continuation of it, a hero image or sticky header included.
    /// Until the first sample of a page arrives it is the page's background color. Deliberately never the
    /// declared theme color, which sites often set to a brand color that matches nothing under the strip.
    /// Nil while the tab is blank.
    var chromeColor: NSColor? {
        if let reloadHold { return reloadHold.chromeColor }
        return isBlank ? nil : edge.color ?? webView.underPageBackgroundColor?.withAlphaComponent(1)
    }

    /// Reloads the page so that nothing appears to move, and the strip keeps its color meanwhile; see
    /// `ReloadHold`. A tab that is hidden or has no page reloads plainly.
    func reload() {
        guard reloadHold == nil, !isBlank, webView.url != nil, webView.window != nil else { return _ = webView.reload() }
        let release = { [weak self] in
            guard let self else { return }
            reloadHold = nil
            owner?.tabChromeDidChange(self)
        }
        ReloadHold.begin(in: webView, chromeColor: chromeColor, onEnd: release) { [weak self] hold in
            self?.reloadHold = hold
            self?.webView.reload()
        }
    }

    /// A tab's first page fades in once it commits, instead of popping in over the address field.
    func load(_ url: URL) {
        if webView.url == nil { webView.alphaValue = 0 }
        isBlank = false
        isOmniboxOpen = false
        omniboxDraft = ""
        webView.load(URLRequest(url: url))
    }

    /// Loads one authentication request, including headers that apply only to its first navigation.
    func loadAuthentication(_ request: ASWebAuthenticationSessionRequest) {
        authenticationRequest = request
        isBlank = false
        isOmniboxOpen = false
        var urlRequest = URLRequest(url: request.url)
        request.additionalHeaderFields?.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
        webView.load(urlRequest)
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
        // Safari's version has matched the system's since 26; before that it ran three ahead of macOS.
        let system = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(system >= 26 ? system : system + 3).0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.addUserScript(
            WKUserScript(source: EdgeChangeRouter.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(EdgeChangeRouter.shared, name: EdgeChangeRouter.name)
        return configuration
    }

    private func changed(_ extensionProperties: WKWebExtension.TabChangedProperties = []) {
        owner?.tabDidChange(self, extensionProperties: extensionProperties)
    }

    private func titleChanged() {
        if let url = webView.url, let title = webView.title, !title.isEmpty {
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

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        guard let url = action.request.url else { return decisionHandler(.allow) }
        if action.targetFrame?.isMainFrame != false, completeAuthenticationIfNeeded(with: url) {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "aero", url.path.hasPrefix("/action/") {
            if webView.url?.scheme == "aero" {
                switch url.host {
                case "extensions": owner?.handleExtensionCatalogAction(url, from: self)
                case "settings": owner?.handleSettingsAction(url, from: self)
                default: break
                }
            }
            return decisionHandler(.cancel)
        }
        guard action.navigationType == .linkActivated else {
            return decisionHandler(.allow)
        }
        if action.modifierFlags.contains(.command) {
            owner?.openTab(url: url, inBackground: true)
            return decisionHandler(.cancel)
        }
        // Links to other apps (mailto:, tel:, custom schemes) go to the system.
        if !["http", "https", "aero", "about", "blob", "data", "file", "javascript"].contains(
            url.scheme?.lowercased() ?? "")
        {
            NSWorkspace.shared.open(url)
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

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { owner?.tabs.firstIndex { $0 === self } ?? NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }

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
        owner?.downloads.accept(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        owner?.downloads.accept(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { History.shared.visit(url) }
        edge.reset()
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
        owner?.openTab(configuration: configuration).webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.close(self)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        runPanel(message: message, buttons: ["OK"]) { _, _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        runPanel(message: message, buttons: ["OK", "Cancel"]) { confirmed, _ in completionHandler(confirmed) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void
    ) {
        runPanel(message: prompt, buttons: ["OK", "Cancel"], input: defaultText ?? "") { confirmed, text in
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

    /// Leaves camera and microphone approval to WebKit's per-origin system prompt.
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }

    /// Leaves location approval to WebKit's per-origin system prompt on macOS 27 and later.
    @available(macOS 27.0, *)
    func webView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.prompt)
    }

    /// Shows a page's alert/confirm/prompt as a sheet. `done` gets whether the first button was
    /// chosen and the input text (empty when `input` is nil).
    private func runPanel(
        message: String, buttons: [String], input: String? = nil,
        done: @escaping (Bool, String) -> Void
    ) {
        guard let window = webView.window else { return done(false, "") }
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? appName
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
