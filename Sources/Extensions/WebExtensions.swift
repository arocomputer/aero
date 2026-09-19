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
final class WebExtensions: NSObject, WKWebExtensionControllerDelegate {
    static let shared = WebExtensions()

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
    var onChange: (() -> Void)?

    private let recordsKey = "extensions.v1"
    private var records: [Record]
    private var contextRecords: [ObjectIdentifier: Record] = [:]

    override private init() {
        let stored =
            UserDefaults.standard.data(forKey: recordsKey)
            .flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        records = stored

        let base = WKWebViewConfiguration()
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
    func loadInstalled() {
        Task {
            for record in records where !contextRecords.values.contains(record) {
                try? await load(record: record)
            }
            changed()
        }
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

    /// Returns the extension's own artwork, falling back to Aero's neutral extension tile.
    func iconDataURL(for context: WKWebExtensionContext) -> String {
        imageDataURL(context.webExtension.icon(for: CGSize(width: 128, height: 128)))
    }

    func context(uniqueIdentifier: String) -> WKWebExtensionContext? {
        contexts.first { $0.uniqueIdentifier == uniqueIdentifier }
    }

    /// Unloads an extension and removes the private copy Aero installed.
    func remove(_ context: WKWebExtensionContext) throws {
        guard let record = contextRecords.removeValue(forKey: ObjectIdentifier(context)) else { return }
        try controller.unload(context)
        contexts.removeAll { $0 === context }
        records.removeAll { $0 == record }
        if let filename = record.filename {
            try? FileManager.default.removeItem(at: extensionsDirectory.appendingPathComponent(filename))
        }
        saveRecords()
        changed()
    }

    private var extensionsDirectory: URL {
        let directory = AppPaths.support.appendingPathComponent("Extensions", isDirectory: true)
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
        #if DEBUG
            context.isInspectable = true
        #endif
        try controller.load(context)
        contexts.append(context)
        contextRecords[ObjectIdentifier(context)] = record
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

    private func imageDataURL(_ image: NSImage?) -> String {
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            let svg = """
                <svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"><rect width="128" height="128" rx="28" fill="#73737a"/><path d="M18 108C32 66 51 16 64 16s32 50 46 92C92 85 79 65 64 65s-28 20-46 43Z" fill="white"/></svg>
                """
            return "data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())"
        }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: recordsKey) }
    }

    private func changed() {
        onChange?()
        for window in browserWindows { window.extensionsDidChange() }
    }

    private var browserWindows: [BrowserWindowController] {
        NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
    }

    private var focusedWindow: BrowserWindowController? {
        NSApp.keyWindow?.windowController as? BrowserWindowController
    }

    // MARK: WKWebExtensionControllerDelegate

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
        let window = configuration.window as? BrowserWindowController ?? focusedWindow ?? browserWindows.first
        guard let window else { return completionHandler(nil, extensionError("No browser window is open.")) }
        let tab = window.openTab(url: configuration.url, inBackground: !configuration.shouldBeActive)
        if configuration.shouldBePinned { window.setPinned(true, tab: tab) }
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
        guard !configuration.shouldBePrivate,
            let app = NSApp.delegate as? AppDelegate
        else {
            return completionHandler(nil, extensionError("Private extension windows are not supported."))
        }
        let window = app.openWindow(url: configuration.tabURLs.first)
        for url in configuration.tabURLs.dropFirst() { window.openTab(url: url, inBackground: true) }
        completionHandler(window, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        confirmAccess(context: context, detail: names) { completionHandler($0 ? permissions : [], nil) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let names = urls.map(\.absoluteString).sorted().joined(separator: "\n")
        confirmAccess(context: context, detail: names) { completionHandler($0 ? urls : [], nil) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let names = patterns.map(\.string).sorted().joined(separator: "\n")
        confirmAccess(context: context, detail: names) { completionHandler($0 ? patterns : [], nil) }
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
