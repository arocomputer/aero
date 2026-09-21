import AppKit
import WebKit
import SecurityInterface

/// Captures a certificate's origin and trust object together so navigation cannot retarget an open menu.
private final class CertificateDetails: NSObject {
    let trust: SecTrust
    let host: String
    init(trust: SecTrust, host: String) { self.trust = trust; self.host = host }
}

/// Native site identity and controls, outside the page's DOM and styled by the system.
extension WindowController {
    func showSiteInformation(for tab: Tab, relativeTo view: NSView) {
        guard let url = tab.url, AddressInput.isWeb(url), let host = url.host else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let identity = menu.addItem(
            withTitle: BrowsingSecurity.label(scheme: url.scheme ?? "", host: host, port: url.port ?? 0),
            action: nil, keyEquivalent: "")
        identity.isEnabled = false
        let encrypted =
            url == tab.webView.url && url.scheme == "https" && tab.webView.serverTrust != nil && tab.webView.hasOnlySecureContent
        let connection = menu.addItem(
            withTitle: encrypted ? "Connection encrypted" : "Connection is not fully encrypted", action: nil, keyEquivalent: "")
        connection.isEnabled = false
        if !tab.webView.isLoading, url == tab.webView.url, url.scheme == "https", let trust = tab.webView.serverTrust {
            let certificate = menu.addItem(withTitle: "Certificate details…", action: #selector(showCertificate(_:)), keyEquivalent: "")
            certificate.target = self
            certificate.representedObject = CertificateDetails(trust: trust, host: host)
        }
        menu.addItem(.separator())
        let protection = menu.addItem(
            withTitle: "Block known trackers", action: #selector(toggleSiteProtection(_:)), keyEquivalent: "")
        protection.target = self
        protection.representedObject = url
        protection.state = TrackerProtection.shared.isEnabled(for: url) ? .on : .off
        protection.isEnabled = Settings.trackerBlocking && TrackerProtection.shared.isReady
        if !tab.recordsActivity { protection.isEnabled = false }
        for kind in SitePolicy.Feature.allCases {
            if kind == .location {
                if #available(macOS 27.0, *) {} else { continue }
            }
            let item = menu.addItem(withTitle: kind.name, action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for decision in SitePolicy.Decision.allCases where decision != .ask || kind.supportsAsk {
                let choice = choices.addItem(
                    withTitle: decision.rawValue.capitalized, action: #selector(changeSitePermission(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = ["url": url, "kind": kind.rawValue, "decision": decision.rawValue, "tab": tab] as [String: Any]
                choice.state = tab.policy(kind, at: url) == decision ? .on : .off
            }
            if [.camera, .microphone, .location].contains(kind) {
                let once = choices.addItem(withTitle: "Allow for this visit", action: #selector(allowSiteForVisit(_:)), keyEquivalent: "")
                once.target = self
                once.representedObject = ["tab": tab, "url": url, "kind": kind.rawValue] as [String: Any]
            }
            item.submenu = choices
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear website data…", action: #selector(clearSiteData(_:)), keyEquivalent: "")
        clear.target = self
        clear.representedObject = ["host": host, "store": tab.webView.configuration.websiteDataStore] as [String: Any]
        let security = menu.addItem(withTitle: "Web security", action: nil, keyEquivalent: "")
        let modes = NSMenu()
        for mode in WebSecurityMode.available {
            let item = modes.addItem(withTitle: mode.name, action: #selector(changeWebSecurity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["tab": tab, "url": url, "mode": mode.rawValue] as [String: Any]
            item.state = tab.securityMode(at: url) == mode ? .on : .off
        }
        security.submenu = modes
        if tab.recordsActivity {
            let settings = menu.addItem(withTitle: "Site settings…", action: #selector(openSitePreferences(_:)), keyEquivalent: "")
            settings.target = self
            settings.representedObject = url
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 5), in: view)
    }

    @objc private func toggleSiteProtection(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let enabled = !TrackerProtection.shared.isEnabled(for: url)
        Task { @MainActor in
            do {
                try await TrackerProtection.shared.setEnabled(enabled, for: url)
                for window in NSApp.windows.compactMap({ $0.windowController as? WindowController }) {
                    for tab in window.tabs where tab.url?.host == url.host { tab.reload() }
                }
            } catch {
                guard let window else { return }
                let alert = NSAlert()
                alert.messageText = "Could not change tracker protection"
                alert.informativeText = "The previous protection remains active. Try again."
                alert.beginSheetModal(for: window) { _ in }
            }
        }
    }

    @objc private func showCertificate(_ sender: NSMenuItem) {
        guard let details = sender.representedObject as? CertificateDetails, let window else { return }
        let panel = SFCertificatePanel()
        panel.title = "Certificate for \(details.host)"
        panel.beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: details.trust, showGroup: true)
    }

    @objc private func changeWebSecurity(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: Any], let tab = values["tab"] as? Tab,
            let url = values["url"] as? URL, let origin = BrowsingSecurity.origin(url),
            let raw = values["mode"] as? String, let mode = WebSecurityMode(rawValue: raw)
        else { return }
        if tab.recordsActivity { WebSecurityMode.set(mode, for: origin) } else { tab.privateSecurityModes[origin] = mode }
        tab.reload()
    }

    @objc private func openSitePreferences(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openSiteSettings(url) }
    }

    @objc private func changeSitePermission(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: Any], let url = values["url"] as? URL,
            let raw = values["kind"] as? String, let kind = SitePolicy.Feature(rawValue: raw),
            let rawDecision = values["decision"] as? String, let decision = SitePolicy.Decision(rawValue: rawDecision),
            let tab = values["tab"] as? Tab, let origin = BrowsingSecurity.origin(url)
        else { return }
        tab.clearTemporaryPolicy(kind, at: url)
        if !tab.recordsActivity {
            tab.temporarySitePolicies[kind.rawValue + origin] = decision
        } else {
            SitePolicy.set(decision, feature: kind, origin: origin)
        }
        if decision != .allow, let permission = SitePermissions.Kind(rawValue: kind.rawValue) {
            let targets =
                tab.recordsActivity
                ? NSApp.windows.compactMap { $0.windowController as? WindowController }.flatMap(\.tabs).filter(\.recordsActivity) : [tab]
            for target in targets {
                if target.recordsActivity { target.clearTemporaryPolicy(kind, at: url) }
                target.revokePermission(permission, at: url)
            }
        }
        if [.javaScript, .popups, .images].contains(kind) { tab.reload() }
        if kind == .media { tab.applyPolicyChanges() }
    }

    @objc private func allowSiteForVisit(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: Any], let tab = values["tab"] as? Tab,
            let url = values["url"] as? URL, let raw = values["kind"] as? String, let feature = SitePolicy.Feature(rawValue: raw)
        else { return }
        tab.allowForVisit(feature, at: url)
    }

    /// WebKit groups records by registrable domain, so confirmation names the full deletion scope.
    @objc private func clearSiteData(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: Any], let host = values["host"] as? String,
            let store = values["store"] as? WKWebsiteDataStore, let window
        else { return }
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let records = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
            let alert = NSAlert()
            alert.messageText = "Clear website data?"
            let names = Set(records.map(\.displayName)).sorted().joined(separator: ", ")
            alert.informativeText =
                records.isEmpty
                ? "No stored website data was found for this site."
                : "This removes cookies and storage for \(names), including its subdomains, and may sign you out. Open pages can create new data."
            alert.addButton(withTitle: "Cancel")
            if !records.isEmpty { alert.addButton(withTitle: "Clear Data") }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn else { return }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
            }
        }
    }
}
