import AppKit
import WebKit

/// Library pages expose local records; editing and file access stay in native sheets.
extension WindowController {
    @objc func openHistoryPage(_ sender: Any?) { openLibrary("history") }
    @objc func openBookmarksPage(_ sender: Any?) { openLibrary("bookmarks") }

    func openLibrary(_ name: String) {
        guard ["history", "bookmarks", "downloads"].contains(name) else { return }
        if let tab = tabs.first(where: { $0.url?.scheme == "aero" && $0.url?.host == name }) {
            select(tab)
            tab.webView.reload()
        } else {
            openTab(url: URL(string: "aero://\(name)")!)
        }
    }

    @objc func bookmarkPage(_ sender: Any?) {
        guard let url = active?.url, AddressInput.isWeb(url) else { return }
        editBookmark(
            Bookmarks.shared.entries.first { $0.url == url }
                ?? .init(title: active?.title ?? url.host ?? "Bookmark", url: url, folder: "Bookmarks"))
    }

    func handleLibraryAction(_ url: URL, from tab: Tab) {
        let action = String(url.path.dropFirst("/action/".count))
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        if url.host == "history" {
            if action == "clear" { deleteBrowsingData(nil) }
            if action == "remove", let id, let number = Int(id) { History.shared.removeVisit(number); tab.webView.reload() }
        } else if url.host == "downloads", let id, let uuid = UUID(uuidString: id),
            let item = downloads.items.first(where: { $0.id == uuid })
        {
            switch action {
            case "pause": item.pause()
            case "cancel": item.cancel()
            case "retry": item.restart(in: tab.webView)
            case "reveal": item.reveal()
            case "remove": downloads.remove(uuid)
            default: break
            }
            tab.webView.reload()
        } else if url.host == "site-data", action == "remove", let window,
            let site = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "site" })?.value
        {
            let store = tab.webView.configuration.websiteDataStore
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let matches = records.filter { $0.displayName == site }
                guard !matches.isEmpty else { return }
                let alert = NSAlert()
                alert.messageText = "Remove data for \(site)?"
                alert.informativeText =
                    "Cookies and stored data for this website and its subdomains will be removed. This may sign you out."
                alert.addButton(withTitle: "Remove Data")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matches) { tab.webView.reload() }
                }
            }
        } else if url.host == "bookmarks" {
            switch action {
            case "add": editBookmark(nil)
            case "edit":
                if let id, let entry = Bookmarks.shared.entries.first(where: { $0.id.uuidString == id }) { editBookmark(entry) }
            case "import": importBookmarks()
            case "export": exportBookmarks()
            default: break
            }
        }
    }

    /// Edits a bookmark, including its named folder, without placing mutable controls in page content.
    private func editBookmark(_ original: Bookmarks.Entry?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = original == nil ? "Add bookmark" : "Edit bookmark"
        alert.informativeText = "Bookmarks are kept until you remove them, including links saved while browsing privately."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if let original, Bookmarks.shared.entries.contains(where: { $0.id == original.id }) { alert.addButton(withTitle: "Remove") }
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 116))
        let fields = [
            NSTextField(string: original?.title ?? ""), NSTextField(string: original?.url.absoluteString ?? ""),
            NSTextField(string: original?.folder ?? "Bookmarks"),
        ]
        for (index, label) in ["Name", "Address", "Folder"].enumerated() {
            let title = NSTextField(labelWithString: label)
            title.frame = NSRect(x: 0, y: 84 - index * 36, width: 64, height: 22)
            fields[index].frame = NSRect(x: 72, y: 84 - index * 36, width: 308, height: 24)
            fields[index].setAccessibilityLabel(label)
            form.addSubview(title)
            form.addSubview(fields[index])
        }
        alert.accessoryView = form
        alert.beginSheetModal(for: window) { response in
            do {
                if response == .alertThirdButtonReturn, let original {
                    try Bookmarks.shared.remove(original.id)
                } else if response == .alertFirstButtonReturn {
                    var address = fields[1].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !address.contains("://") { address = "https://" + address }
                    guard let url = URL(string: address), AddressInput.isWeb(url), url.host?.isEmpty == false else {
                        throw NSError(
                            domain: "Bookmarks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid HTTP or HTTPS address."])
                    }
                    var entry = original ?? Bookmarks.Entry(title: "", url: url, folder: "")
                    entry.url = url
                    entry.title = fields[0].stringValue.isEmpty ? AddressInput.display(for: url) : fields[0].stringValue
                    entry.folder = fields[2].stringValue.isEmpty ? "Bookmarks" : fields[2].stringValue
                    try Bookmarks.shared.save(entry)
                }
                self.refreshLibrary("bookmarks")
            } catch { NSAlert(error: error).beginSheetModal(for: window) { _ in } }
        }
    }

    private func importBookmarks() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a bookmarks HTML file exported by another browser."
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: 16_777_217) ?? Data()
                _ = try Bookmarks.shared.importHTML(String(decoding: data, as: UTF8.self))
                self.refreshLibrary("bookmarks")
            } catch { NSAlert(error: error).beginSheetModal(for: window) { _ in } }
        }
    }

    private func exportBookmarks() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Bookmarks.html"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Bookmarks.shared.exportHTML().write(to: url, atomically: true, encoding: .utf8) } catch {
                NSAlert(error: error).beginSheetModal(for: window) { _ in }
            }
        }
    }

    func refreshLibrary(_ host: String) {
        for controller in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
            for tab in controller.tabs where tab.url?.scheme == "aero" && tab.url?.host == host { tab.webView.reload() }
        }
    }
}
