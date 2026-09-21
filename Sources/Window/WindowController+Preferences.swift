import AppKit

/// Native editors for structured preferences keep validation and persistence outside page JavaScript.
extension WindowController {
    func editSite() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Configure a website"
        alert.informativeText = "Enter the website address. Rules use its scheme, host and port."
        let field = NSTextField(string: "")
        field.placeholderString = "https://example.com"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Open Site Settings")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: address.contains("://") ? address : "https://" + address), BrowsingSecurity.origin(url) != nil
            else { return }
            self.openSiteSettings(url)
        }
    }

    func openSiteSettings(_ url: URL) {
        guard let origin = BrowsingSecurity.origin(url) else { return }
        var destination = URLComponents(string: "aero://settings")!
        destination.queryItems = [URLQueryItem(name: "site", value: origin)]
        destination.fragment = "websites"
        openTab(url: destination.url!)
    }

    /// DNS changes require an explicit native confirmation because they apply to all apps on the Mac.
    func configureSecureDNS() {
        guard let window else { return }
        guard SecureDNS.shared.hasEntitlement else {
            let alert = NSAlert()
            alert.messageText = "Encrypted DNS requires a signed build"
            alert.informativeText = "This build lacks the DNS-settings entitlement. You can configure network settings directly in macOS."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Configure system encrypted DNS"
        alert.informativeText =
            "This affects DNS for all apps. After saving, enable the configuration in macOS Network settings. Custom providers require an HTTPS URL and bootstrap IP addresses."
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 110))
        let provider = NSPopUpButton(frame: NSRect(x: 0, y: 78, width: 420, height: 28))
        provider.addItems(withTitles: ["Use system settings", "Cloudflare", "Google", "Quad9", "Custom provider"])
        let keys = ["system", "cloudflare", "google", "quad9", "custom"]
        provider.selectItem(at: keys.firstIndex(of: SecureDNS.shared.selection) ?? 0)
        let address = NSTextField(frame: NSRect(x: 0, y: 42, width: 420, height: 24))
        address.placeholderString = "Custom resolver HTTPS URL"
        address.stringValue = SecureDNS.shared.configuration?.url.absoluteString ?? ""
        let bootstrap = NSTextField(frame: NSRect(x: 0, y: 6, width: 420, height: 24))
        bootstrap.placeholderString = "Bootstrap IP addresses, separated by commas"
        bootstrap.stringValue = SecureDNS.shared.configuration?.addresses.joined(separator: ", ") ?? ""
        [provider, address, bootstrap].forEach(form.addSubview)
        alert.accessoryView = form
        alert.addButton(withTitle: "Save Configuration")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let key = keys[provider.indexOfSelectedItem]
            let servers = bootstrap.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            Task { @MainActor in
                do {
                    try await SecureDNS.shared.configure(key, customURL: URL(string: address.stringValue), addresses: servers)
                    self.refreshLibrary("settings")
                } catch { NSAlert(error: error).beginSheetModal(for: window) { _ in } }
            }
        }
    }

    func editSearchEngine(_ existing: CustomSearch.Engine?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add search engine" : "Edit search engine"
        alert.informativeText =
            "Use %s where the search words belong in the URL. A shortcut lets you search this site from the address field."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if existing != nil { alert.addButton(withTitle: "Remove") }
        let fields = [
            NSTextField(string: existing?.name ?? ""), NSTextField(string: existing?.shortcut ?? ""),
            NSTextField(string: existing?.template ?? ""),
        ]
        fields[2].placeholderString = "https://example.com/search?q=%s"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 110))
        for (index, name) in ["Name", "Shortcut", "Search URL"].enumerated() {
            let label = NSTextField(labelWithString: name)
            label.frame = NSRect(x: 0, y: 80 - index * 36, width: 85, height: 24)
            fields[index].frame = NSRect(x: 90, y: 80 - index * 36, width: 330, height: 24)
            fields[index].setAccessibilityLabel(name)
            form.addSubview(label)
            form.addSubview(fields[index])
        }
        alert.accessoryView = form
        alert.beginSheetModal(for: window) { response in
            do {
                if response == .alertThirdButtonReturn, let existing {
                    try CustomSearch.remove(existing.id)
                } else if response == .alertFirstButtonReturn {
                    var engine = existing ?? CustomSearch.Engine(name: "", shortcut: "", template: "")
                    engine.name = fields[0].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    engine.shortcut = fields[1].stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    engine.template = fields[2].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    try CustomSearch.save(engine)
                }
                self.refreshLibrary("settings")
            } catch { NSAlert(error: error).beginSheetModal(for: window) { _ in } }
        }
    }

    /// Startup addresses and sleep exceptions are edited as one address per line.
    func editAddressList(key: String, title: String) {
        guard ["StartupPages", "NeverSleepSites"].contains(key), let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Enter one HTTP or HTTPS address per line."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 13)
        editor.string = (UserDefaults.standard.stringArray(forKey: key) ?? []).joined(separator: "\n")
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let lines = editor.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                !$0.isEmpty
            }
            let urls = lines.compactMap { URL(string: $0.contains("://") ? $0 : "https://" + $0) }
            guard urls.count == lines.count, urls.allSatisfy({ AddressInput.isWeb($0) && $0.host?.isEmpty == false }) else {
                let error = NSError(
                    domain: "Preferences", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Every line must be a valid HTTP or HTTPS address."])
                NSAlert(error: error).beginSheetModal(for: window) { _ in }
                return
            }
            UserDefaults.standard.set(urls.map { key == "NeverSleepSites" ? BrowsingSecurity.origin($0)! : $0.absoluteString }, forKey: key)
            self.refreshLibrary("settings")
        }
    }
}
