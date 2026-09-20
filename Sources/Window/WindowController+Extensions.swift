import AppKit
import WebKit

/// WebExtensions in a window: the extensions menu, the catalog page's actions, and the window as the
/// extension runtime sees it.
extension WindowController {
    /// Announces a fully constructed window and its tabs to the shared extension runtime.
    func registerWithExtensions() {
        guard !isRegisteredWithExtensions else { return }
        isRegisteredWithExtensions = true
        let controller = WebExtensions.shared.controller
        controller.didOpenWindow(self)
        tabs.forEach(controller.didOpenTab)
        if let active { controller.didActivateTab(active) }
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
