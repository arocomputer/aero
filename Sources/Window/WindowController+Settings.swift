import AppKit
import WebKit

/// The settings page's privileged actions, which arrive as `aero://settings/action/…` links.
extension WindowController {
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
            guard let value, let appearance = Appearance(rawValue: value) else { return }
            Settings.appearance = appearance
            tab.webView.reload()
        case "favicons":
            guard let value, ["on", "off"].contains(value) else { return }
            Settings.showsFavicons = value == "on"
            (NSApp.delegate as? AppDelegate)?.faviconsSettingChanged()
            tab.webView.reload()
        case "search-engine":
            guard let value, let engine = SearchEngine(rawValue: value) else { return }
            Settings.searchEngine = engine
            tab.webView.reload()
        case "choose-downloads":
            chooseDownloadDirectory(for: tab)
        case "show-downloads":
            NSWorkspace.shared.open(Settings.downloadDirectory)
        case "clear-history":
            confirmSettingsChange(
                title: "Clear browsing history?",
                message: "\(appName) will remove saved addresses, page titles and site icons from suggestions.",
                button: "Clear History"
            ) {
                History.shared.clear()
                Favicons.shared.clear()
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
        panel.directoryURL = Settings.downloadDirectory
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Settings.downloadDirectory = url
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
}
