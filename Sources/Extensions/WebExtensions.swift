import AppKit
import WebKit

/// An installed macOS app that contains at least one manifest-backed WebExtension bundle.
struct NativeExtensionApp {
    let name: String
    let bundleIdentifier: String
    let iconDataURL: String
}

/// Loads user-installed WebExtensions into one persistent Safari-style browsing session.
/// Aero supplies tab, window, permission and popup behavior while WebKit runs the extensions.
@MainActor final class WebExtensions: NSObject, WKWebExtensionControllerDelegate {
    static let shared = WebExtensions(
        defaults: .standard, directory: AppPaths.support.appendingPathComponent("Extensions", isDirectory: true))

    private struct Record: Codable, Equatable {
        let id: UUID
        let filename: String?
        let appBundleIdentifier: String?
        let extensionBundleIdentifier: String?

        init(
            id: UUID, filename: String? = nil, appBundleIdentifier: String? = nil,
            extensionBundleIdentifier: String? = nil
        ) {
            self.id = id
            self.filename = filename
            self.appBundleIdentifier = appBundleIdentifier
            self.extensionBundleIdentifier = extensionBundleIdentifier
        }
    }

    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []
    var enabledContexts: [WKWebExtensionContext] { safeMode ? [] : contexts.filter(isEnabled) }
    let safeMode: Bool
    var onChange: (() -> Void)?

    private let recordsKey = "extensions.v1"
    private var records: [Record]
    private var contextRecords: [ObjectIdentifier: Record] = [:]
    private var loadErrors: [UUID: String] = [:]
    private let defaults: UserDefaults
    private let directory: URL

    /// Owns installation records and files. Tests use a disposable defaults suite and directory.
    init(defaults: UserDefaults, directory: URL, safeMode: Bool = ProcessInfo.processInfo.arguments.contains("--disable-extensions")) {
        self.defaults = defaults
        self.directory = directory
        self.safeMode = safeMode
        let stored =
            defaults.data(forKey: recordsKey)
            .flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        records = stored

        let base = WKWebViewConfiguration()
        BrowsingSecurity.configure(base)
        base.websiteDataStore = .default()
        let configuration = WKWebExtensionController.Configuration.default()
        configuration.defaultWebsiteDataStore = .default()
        configuration.webViewConfiguration = base
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    /// Connects a normal page web view to the shared extension runtime.
    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = .default()
        configuration.webExtensionController = controller
    }

    /// Loads extensions copied into Aero's Application Support directory on earlier launches.
    func loadInstalled() async {
        for record in records where !contextRecords.values.contains(record) {
            do {
                try await load(record: record)
                loadErrors.removeValue(forKey: record.id)
            } catch { loadErrors[record.id] = error.localizedDescription }
        }
        changed()
    }

    /// Failed installations remain visible and removable even when WebKit cannot create a context.
    var failedInstallations: [(id: String, name: String, message: String)] {
        records.compactMap { record in
            guard let message = loadErrors[record.id] else { return nil }
            return (record.id.uuidString.lowercased(), record.appBundleIdentifier ?? "Local extension", message)
        }
    }

    func removeFailedInstallation(_ identifier: String) {
        guard let id = UUID(uuidString: identifier), loadErrors[id] != nil,
            let record = records.first(where: { $0.id == id })
        else { return }
        if let filename = record.filename { try? FileManager.default.removeItem(at: extensionsDirectory.appendingPathComponent(filename)) }
        records.removeAll { $0.id == id }
        loadErrors.removeValue(forKey: id)
        let disabled = (defaults.stringArray(forKey: "DisabledExtensions") ?? []).filter { $0 != identifier }
        defaults.set(disabled, forKey: "DisabledExtensions")
        saveRecords()
        changed()
    }

    /// Copies a directory or ZIP into Aero's data directory, then validates and loads it through WebKit.
    func install(from source: URL) async throws {
        let id = UUID()
        let suffix = source.pathExtension.isEmpty ? "extension" : source.pathExtension
        let filename = "\(id.uuidString).\(suffix)"
        let destination = extensionsDirectory.appendingPathComponent(filename, isDirectory: source.hasDirectoryPath)
        try FileManager.default.copyItem(at: source, to: destination)

        let record = Record(id: id, filename: filename)
        do {
            try await load(record: record)
            records.append(record)
            saveRecords()
            changed()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Loads a signed Safari WebExtension from an installed macOS app and follows that app's updates.
    func install(appBundleIdentifier: String) async throws {
        if let record = records.first(where: { $0.appBundleIdentifier == appBundleIdentifier }) {
            if contextRecords.values.contains(record) { return }
            try await load(record: record)
            changed()
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier) else {
            throw extensionError("The extension app is not installed.")
        }
        let candidates = appExtensionBundles(in: appURL)
        var lastError: Error?
        for bundle in candidates {
            let record = Record(
                id: UUID(), appBundleIdentifier: appBundleIdentifier,
                extensionBundleIdentifier: bundle.bundleIdentifier)
            do {
                try await load(record: record, appExtensionBundle: bundle)
                records.append(record)
                saveRecords()
                changed()
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? extensionError("The app does not contain a compatible Safari WebExtension.")
    }

    func isInstalled(appBundleIdentifier: String) -> Bool {
        contextRecords.values.contains { $0.appBundleIdentifier == appBundleIdentifier }
    }

    /// Finds every installed app whose plug-ins contain a manifest WebKit can load.
    func nativeExtensionApps() -> [NativeExtensionApp] {
        let files = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            files.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var appURLs: [URL] = []
        for root in roots {
            let children =
                (try? files.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for child in children {
                if child.pathExtension == "app" {
                    appURLs.append(child)
                } else if child.hasDirectoryPath {
                    let nested =
                        (try? files.contentsOfDirectory(
                            at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    appURLs.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                }
            }
        }

        return appURLs.compactMap { url in
            guard !appExtensionBundles(in: url).isEmpty, let bundle = Bundle(url: url),
                let identifier = bundle.bundleIdentifier
            else { return nil }
            let name =
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return NativeExtensionApp(
                name: name, bundleIdentifier: identifier,
                iconDataURL: imageDataURL(NSWorkspace.shared.icon(forFile: url.path)))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Returns the extension's artwork, falling back to Apple's system puzzle-piece symbol.
    func iconDataURL(for context: WKWebExtensionContext) -> String {
        imageDataURL(context.webExtension.icon(for: CGSize(width: 128, height: 128)))
    }
    var fallbackIconDataURL: String { imageDataURL(nil) }

    func context(uniqueIdentifier: String) -> WKWebExtensionContext? {
        contexts.first { $0.uniqueIdentifier == uniqueIdentifier }
    }

    /// Disabled extensions remain installed and inspectable in Settings, but are unloaded from WebKit.
    func isEnabled(_ context: WKWebExtensionContext) -> Bool {
        !(defaults.stringArray(forKey: "DisabledExtensions") ?? []).contains(context.uniqueIdentifier)
    }

    func setEnabled(_ enabled: Bool, for context: WKWebExtensionContext) throws {
        guard enabled != isEnabled(context) else { return }
        savePermissions(context)
        if enabled {
            if !safeMode { try controller.load(context) }
        } else if controller.extensionContexts.contains(context) {
            try controller.unload(context)
        }
        var disabled = Set(defaults.stringArray(forKey: "DisabledExtensions") ?? [])
        if enabled { disabled.remove(context.uniqueIdentifier) } else { disabled.insert(context.uniqueIdentifier) }
        defaults.set(disabled.sorted(), forKey: "DisabledExtensions")
        changed()
    }

    func disableAll() throws {
        for context in enabledContexts { try setEnabled(false, for: context) }
        defaults.set(records.map { $0.id.uuidString.lowercased() }, forKey: "DisabledExtensions")
        changed()
    }

    func installationSource(for context: WKWebExtensionContext) -> String {
        guard let identifier = contextRecords[ObjectIdentifier(context)]?.appBundleIdentifier else { return "Installed from a local file" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url.lastPathComponent }
        return identifier
    }

    /// Unloads an extension and removes the private copy Aero installed.
    func remove(_ context: WKWebExtensionContext) throws {
        guard let record = contextRecords[ObjectIdentifier(context)] else { return }
        if controller.extensionContexts.contains(context) { try controller.unload(context) }
        NotificationCenter.default.removeObserver(self, name: nil, object: context)
        defaults.removeObject(forKey: "ExtensionPermissions.\(context.uniqueIdentifier)")
        if defaults.string(forKey: "NewTabExtension") == context.uniqueIdentifier { defaults.removeObject(forKey: "NewTabExtension") }
        contextRecords.removeValue(forKey: ObjectIdentifier(context))
        let disabled = (defaults.stringArray(forKey: "DisabledExtensions") ?? []).filter { $0 != context.uniqueIdentifier }
        defaults.set(disabled, forKey: "DisabledExtensions")
        contexts.removeAll { $0 === context }
        records.removeAll { $0 == record }
        if let filename = record.filename {
            try? FileManager.default.removeItem(at: extensionsDirectory.appendingPathComponent(filename))
        }
        saveRecords()
        changed()
    }

    private var extensionsDirectory: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func load(record: Record) async throws {
        if let filename = record.filename {
            let url = extensionsDirectory.appendingPathComponent(filename)
            let webExtension = try await WKWebExtension(resourceBaseURL: url)
            return try load(record: record, webExtension: webExtension)
        }
        guard let appIdentifier = record.appBundleIdentifier,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appIdentifier)
        else { throw extensionError("The extension app is no longer installed.") }
        let bundles = appExtensionBundles(in: appURL)
        let bundle = bundles.first { $0.bundleIdentifier == record.extensionBundleIdentifier } ?? bundles.first
        guard let bundle else { throw extensionError("The app no longer contains its Safari WebExtension.") }
        try await load(record: record, appExtensionBundle: bundle)
    }

    private func load(record: Record, appExtensionBundle: Bundle) async throws {
        let webExtension = try await WKWebExtension(appExtensionBundle: appExtensionBundle)
        try load(record: record, webExtension: webExtension)
    }

    private func load(record: Record, webExtension: WKWebExtension) throws {
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.id.uuidString.lowercased()
        if let data = defaults.data(forKey: "ExtensionPermissions.\(context.uniqueIdentifier)"),
            let permissions = try? JSONDecoder().decode(ExtensionPermissions.self, from: data)
        {
            permissions.restore(into: context)
        }
        #if DEBUG
            context.isInspectable = true
        #endif
        if isEnabled(context), !safeMode { try controller.load(context) }
        contexts.append(context)
        contextRecords[ObjectIdentifier(context)] = record
        loadErrors.removeValue(forKey: record.id)
        for name in [
            WKWebExtensionContext.permissionsWereGrantedNotification, WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification, WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(permissionsChanged(_:)), name: name, object: context)
        }
    }

    /// Saves changes from WebKit as well as browser-owned permission controls.
    @objc private func permissionsChanged(_ notification: Notification) {
        guard let context = notification.object as? WKWebExtensionContext else { return }
        savePermissions(context)
    }

    func savePermissions(_ context: WKWebExtensionContext) {
        guard contextRecords[ObjectIdentifier(context)] != nil,
            let data = try? JSONEncoder().encode(ExtensionPermissions(context))
        else { return }
        defaults.set(data, forKey: "ExtensionPermissions.\(context.uniqueIdentifier)")
    }

    /// A new-tab override is opt-in, and never runs while its extension is disabled.
    var newTabContext: WKWebExtensionContext? {
        guard let id = defaults.string(forKey: "NewTabExtension") else { return nil }
        return enabledContexts.first { $0.uniqueIdentifier == id && $0.overrideNewTabPageURL != nil }
    }

    func setNewTabOverride(_ context: WKWebExtensionContext?) {
        defaults.set(context?.uniqueIdentifier, forKey: "NewTabExtension")
        changed()
    }

    func usesNewTabOverride(_ context: WKWebExtensionContext) -> Bool {
        defaults.string(forKey: "NewTabExtension") == context.uniqueIdentifier
    }

    private func appExtensionBundles(in appURL: URL) -> [Bundle] {
        let plugins = appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: plugins, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { url in
            guard url.pathExtension == "appex" else { return false }
            return FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Contents/Resources/manifest.json").path)
        }.compactMap(Bundle.init(url:))
    }

    /// Uses the supplied artwork or Apple's puzzle-piece symbol, rasterized for the local HTML page.
    private func imageDataURL(_ image: NSImage?) -> String {
        let image =
            image
            ?? NSImage(size: NSSize(width: 64, height: 64), flipped: false) { bounds in
                let symbol = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(paletteColors: [.systemGray]))
                symbol?.draw(in: bounds.insetBy(dx: 4, dy: 4))
                return true
            }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return "" }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: recordsKey) }
    }

    private func changed() {
        onChange?()
        for window in browserWindows { window.extensionsDidChange() }
    }

    private var browserWindows: [WindowController] {
        NSApp.orderedWindows.compactMap { $0.windowController as? WindowController }.filter { !$0.isPrivate }
    }

    private var focusedWindow: WindowController? {
        guard let window = NSApp.keyWindow?.windowController as? WindowController, !window.isPrivate else { return nil }
        return window
    }

    // MARK: WKWebExtensionControllerDelegate

    /// Converts an extension-visible insertion index to the array that also holds ephemeral tabs.
    /// The caller excludes the moving tab; the window still enforces its pinned-tab boundary.
    static func insertionIndex(_ index: Int, visibility: [Bool]) -> Int {
        let visibleIndices = visibility.indices.filter { visibility[$0] }
        let target = max(0, index)
        return target < visibleIndices.count ? visibleIndices[target] : visibility.count
    }

    /// Validates the complete transfer before creating a window or changing any tab's owner.
    func validateNewWindow(tabs: [any WKWebExtensionTab], isPrivate: Bool) throws {
        guard !isPrivate else { throw extensionError("Private extension windows are not supported.") }
        var seen = Set<ObjectIdentifier>()
        for candidate in tabs {
            guard let tab = candidate as? Tab, tab.recordsActivity, let owner = tab.owner, !owner.isPrivate,
                owner.tabs.contains(where: { $0 === tab }), seen.insert(ObjectIdentifier(tab)).inserted
            else { throw extensionError("The requested tab is not available for transfer.") }
        }
    }

    /// Extension pages need their context's configuration to load resources and extension APIs.
    func pageConfiguration(for url: URL?, context: WKWebExtensionContext) -> WKWebViewConfiguration? {
        guard let url, url.scheme == context.baseURL.scheme, url.host == context.baseURL.host,
            url.port == context.baseURL.port
        else { return nil }
        return context.webViewConfiguration
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        browserWindows
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        openTab(using: configuration, for: context, completionHandler: completionHandler)
    }

    /// Shares destination, opener and insertion rules between creation and duplication.
    func openTab(
        using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
        fallbackWindow: WindowController? = nil, fallbackURL: URL? = nil,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        if let requested = configuration.window {
            guard let window = requested as? WindowController, !window.isPrivate else {
                return completionHandler(nil, extensionError("The requested window is not available to extensions."))
            }
        }
        let window = configuration.window as? WindowController ?? fallbackWindow ?? focusedWindow ?? browserWindows.first
        let parent = configuration.parentTab as? Tab
        if configuration.parentTab != nil {
            guard let parent, parent.recordsActivity, let window, !window.isPrivate, parent.owner === window,
                window.tabs.contains(where: { $0 === parent })
            else { return completionHandler(nil, extensionError("The parent tab must belong to the requested ordinary window.")) }
        }
        let url = configuration.url ?? fallbackURL
        let viewConfiguration = pageConfiguration(for: url, context: context)
        if window == nil {
            guard
                let created = (NSApp.delegate as? AppDelegate)?.openWindow(
                    url: url, configuration: viewConfiguration, restorePins: false, focused: configuration.shouldBeActive),
                let tab = created.active
            else {
                return completionHandler(nil, extensionError("No ordinary browser window is available."))
            }
            if configuration.shouldBePinned { created.setPinned(true, tab: tab) }
            if configuration.index != NSNotFound { created.moveExtensionTab(tab, to: configuration.index) }
            return completionHandler(tab, nil)
        }
        guard let window, !window.isPrivate else {
            return completionHandler(nil, extensionError("Private tabs are not shared with extensions."))
        }
        let tab = window.openTab(url: url, configuration: viewConfiguration, inBackground: !configuration.shouldBeActive, opener: parent)
        if configuration.shouldBePinned { window.setPinned(true, tab: tab) }
        if configuration.index != NSNotFound { window.moveExtensionTab(tab, to: configuration.index) }
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
        do {
            try validateNewWindow(tabs: configuration.tabs, isPrivate: configuration.shouldBePrivate)
            if !configuration.shouldBeFocused && configuration.windowState == .fullscreen {
                throw extensionError("A fullscreen window must be focused.")
            }
        } catch {
            return completionHandler(nil, error)
        }
        guard let app = NSApp.delegate as? AppDelegate else {
            return completionHandler(nil, extensionError("No ordinary browser window is available."))
        }
        let window = app.openWindow(
            url: configuration.tabURLs.first,
            configuration: pageConfiguration(for: configuration.tabURLs.first, context: context), windowType: configuration.windowType,
            restorePins: false, initialTabs: configuration.tabs.compactMap { $0 as? Tab }, focused: configuration.shouldBeFocused)
        for url in configuration.tabURLs.dropFirst() {
            window.openTab(url: url, configuration: pageConfiguration(for: url, context: context), inBackground: true)
        }
        window.setFrame(configuration.frame, for: context) { _ in }
        window.setWindowState(configuration.windowState, for: context) { _ in }
        completionHandler(window, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        confirmAccess(context: context, detail: names) { allowed in
            for permission in permissions { context.setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly, for: permission) }
            self.savePermissions(context)
            completionHandler(allowed ? permissions : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let names = urls.map(\.absoluteString).sorted().joined(separator: "\n")
        confirmAccess(context: context, detail: names) { allowed in
            for url in urls { context.setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly, for: url) }
            self.savePermissions(context)
            completionHandler(allowed ? urls : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let names = patterns.map(\.string).sorted().joined(separator: "\n")
        confirmAccess(context: context, detail: names) { allowed in
            for pattern in patterns { context.setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly, for: pattern) }
            self.savePermissions(context)
            completionHandler(allowed ? patterns : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        changed()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void
    ) {
        guard let window = (action.associatedTab as? Tab)?.owner ?? focusedWindow,
            !window.isPrivate,
            action.associatedTab == nil || (action.associatedTab as? Tab)?.recordsActivity == true,
            let anchor = window.extensionActionAnchor,
            let popover = action.popupPopover
        else {
            return completionHandler(extensionError("The extension popup has no browser window."))
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
    }

    private func confirmAccess(context: WKWebExtensionContext, detail: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Allow \(context.webExtension.displayName ?? "this extension")?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        if let window = focusedWindow?.window {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func extensionError(_ message: String) -> NSError {
        let domain = "\(Bundle.main.bundleIdentifier ?? "Browser").WebExtensions"
        return NSError(domain: domain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
