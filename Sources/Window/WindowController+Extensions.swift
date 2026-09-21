import AppKit
import WebKit

/// WebExtensions in a window: the extensions menu, the catalog page's actions, and the window as the
/// extension runtime sees it.
extension WindowController {
    /// Focus notifications must never introduce private or not-yet-registered windows to WebKit.
    var extensionFocusTarget: WindowController? { isRegisteredWithExtensions && !isPrivate ? self : nil }

    /// Announces a fully constructed window and its tabs to the shared extension runtime.
    func registerWithExtensions() {
        guard !isPrivate, !isRegisteredWithExtensions else { return }
        isRegisteredWithExtensions = true
        let controller = WebExtensions.shared.controller
        controller.didOpenWindow(self)
        tabs.filter(\.recordsActivity).forEach(controller.didOpenTab)
        if let active, active.recordsActivity { controller.didActivateTab(active) }
    }

    /// Shows extension actions for the current tab and a route to the full extensions page.
    func showExtensions(relativeTo view: NSView) {
        extensionActionAnchor = view
        let menu = NSMenu(title: "Extensions")
        for context in WebExtensions.shared.enabledContexts {
            let extensionItem = NSMenuItem(title: context.webExtension.displayName ?? "Extension", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            if active?.recordsActivity == true, let action = context.action(for: active) {
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
        for tab in tabs where tab.url?.scheme == "aero" && tab.url?.host == "extensions" { tab.webView.reload() }
    }

    /// Handles privileged links after Tab verifies the initiating local top-level origin.
    func handleExtensionCatalogAction(_ url: URL, from tab: Tab) {
        let action = String(url.path.dropFirst("/action/".count))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value
        let bundleIdentifier = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "bundle" })?.value
        switch action {
        case "reset-denials":
            guard let id, let context = WebExtensions.shared.context(uniqueIdentifier: id) else { return }
            context.deniedPermissions = [:]
            context.deniedPermissionMatchPatterns = [:]
            WebExtensions.shared.savePermissions(context)
            tab.webView.reload()
        case "new-tab":
            guard let id, let context = WebExtensions.shared.context(uniqueIdentifier: id), context.overrideNewTabPageURL != nil else {
                return
            }
            WebExtensions.shared.setNewTabOverride(WebExtensions.shared.usesNewTabOverride(context) ? nil : context)
            tab.webView.reload()
        case "remove-failed":
            guard let id, WebExtensions.shared.failedInstallations.contains(where: { $0.id == id }), let window else { return }
            let alert = NSAlert()
            alert.messageText = "Remove this unavailable extension?"
            alert.informativeText = "Its installation record and any local copy will be removed."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { WebExtensions.shared.removeFailedInstallation(id) }
            }
        case "toggle":
            let value = components?.queryItems?.first(where: { $0.name == "value" })?.value
            guard let id, let context = WebExtensions.shared.context(uniqueIdentifier: id), let value, ["on", "off"].contains(value) else {
                return
            }
            do {
                try WebExtensions.shared.setEnabled(value == "on", for: context)
                tab.webView.reload()
            } catch {
                tab.webView.reload()
                showExtensionError(error)
            }
        case "revoke-permission":
            guard let id, let context = WebExtensions.shared.context(uniqueIdentifier: id),
                let permission = components?.queryItems?.first(where: { $0.name == "permission" })?.value
            else { return }
            if let granted = context.grantedPermissions.keys.first(where: { $0.rawValue == permission }) {
                context.setPermissionStatus(.unknown, for: granted)
            }
            WebExtensions.shared.savePermissions(context)
            tab.webView.reload()
        case "revoke-site":
            guard let id, let context = WebExtensions.shared.context(uniqueIdentifier: id),
                let pattern = components?.queryItems?.first(where: { $0.name == "pattern" })?.value,
                let granted = context.grantedPermissionMatchPatterns.keys.first(where: { $0.string == pattern })
            else { return }
            context.setPermissionStatus(.unknown, for: granted)
            WebExtensions.shared.savePermissions(context)
            tab.webView.reload()
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
                if isPrivate {
                    (NSApp.delegate as? AppDelegate)?.openWindow(url: url, configuration: context.webViewConfiguration)
                } else {
                    openTab(url: url, configuration: context.webViewConfiguration)
                }
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
        if let existing = tabs.first(where: { $0.url?.scheme == "aero" && $0.url?.host == "extensions" }) {
            select(existing)
            existing.webView.reload()
        } else {
            openTab(url: ExtensionCatalog.pageURL)
        }
    }

    @objc private func runExtensionAction(_ sender: NSMenuItem) {
        guard active?.recordsActivity == true, let action = sender.representedObject as? WKWebExtension.Action,
            let context = action.webExtensionContext
        else { return }
        if let active { context.userGesturePerformed(in: active) }
        context.performAction(for: active)
    }

    @objc private func openExtensionOptions(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? WKWebExtensionContext,
            let url = context.optionsPageURL
        else { return }
        if isPrivate {
            (NSApp.delegate as? AppDelegate)?.openWindow(url: url, configuration: context.webViewConfiguration)
        } else {
            openTab(url: url, configuration: context.webViewConfiguration)
        }
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
                do {
                    try WebExtensions.shared.remove(context)
                    completion?()
                } catch { self.showExtensionError(error) }
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

    // MARK: WKWebExtensionWindow

    /// Reorders a public tab using the indices extensions see, excluding ephemeral sign-in tabs.
    func moveExtensionTab(_ tab: Tab, to index: Int) {
        guard !isPrivate, tab.recordsActivity, tabs.contains(where: { $0 === tab }) else { return }
        let remaining = tabs.filter { $0 !== tab }
        move(tab, to: WebExtensions.insertionIndex(index, visibility: remaining.map(\.recordsActivity)))
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { isPrivate ? [] : tabs.filter(\.recordsActivity) }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        !isPrivate && active?.recordsActivity == true ? active : nil
    }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { extensionWindowType }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(
        _ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void
    ) {
        guard let window else { return completionHandler(NSError(domain: "BrowserExtension", code: 1)) }
        switch state {
        case .minimized: window.miniaturize(nil)
        case .maximized:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isZoomed { window.zoom(nil) }
        case .fullscreen:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .normal:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else if window.isZoomed { window.zoom(nil) }
        @unknown default: break
        }
        completionHandler(nil)
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window else { return completionHandler(NSError(domain: "BrowserExtension", code: 1)) }
        var target = window.frame
        if frame.origin.x.isFinite { target.origin.x = frame.origin.x }
        if frame.origin.y.isFinite { target.origin.y = frame.origin.y }
        if frame.width.isFinite { target.size.width = max(window.minSize.width, frame.width) }
        if frame.height.isFinite { target.size.height = max(window.minSize.height, frame.height) }
        window.setFrame(window.constrainFrameRect(target, to: window.screen ?? NSScreen.main), display: true)
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivate }

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
