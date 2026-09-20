import AppKit
import Foundation

/// Renders Aero's local settings page with the current browser preferences and app metadata.
enum SettingsPage {
    static let pageURL = URL(string: "aero://settings")!

    private static let mark = """
        <svg viewBox="0 0 534 440" aria-hidden="true"><path d="M.777 431.059C59.871 262.605 161.331 0 266.516 0S473.161 262.605 532.255 431.059c1.724 4.915.484 10.746-2.773 6.682C446.411 334.091 362.051 227 266.516 227S86.621 334.091 3.55 437.741C.293 441.805-.947 435.974.777 431.059Z" fill="currentColor"/></svg>
        """

    static func html() -> String {
        let templateURL = Bundle.module.url(forResource: "Settings", withExtension: "html")!
        let template = (try? String(contentsOf: templateURL, encoding: .utf8)) ?? "Settings.html is unavailable."
        let choices = SearchEngine.allCases.map { engine in
            let selected = engine == BrowserSettings.searchEngine ? " selected" : ""
            return #"<option value="\#(engine.rawValue)"\#(selected)>\#(escape(engine.name))</option>"#
        }.joined()
        let appearances = BrowserAppearance.allCases.map { appearance in
            let selected = appearance == BrowserSettings.appearance ? " selected" : ""
            return #"<option value="\#(appearance.rawValue)"\#(selected)>\#(escape(appearance.name))</option>"#
        }.joined()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let versionText = build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
        let folder = BrowserSettings.downloadDirectory.lastPathComponent
        return
            template
            .replacingOccurrences(of: "{{mark}}", with: mark)
            .replacingOccurrences(of: "{{appName}}", with: escape(appName))
            .replacingOccurrences(of: "{{iconGeneral}}", with: symbol("gearshape"))
            .replacingOccurrences(of: "{{iconSearch}}", with: symbol("magnifyingglass"))
            .replacingOccurrences(of: "{{iconPrivacy}}", with: symbol("hand.raised"))
            .replacingOccurrences(of: "{{iconDownloads}}", with: symbol("arrow.down.circle"))
            .replacingOccurrences(of: "{{iconExtensions}}", with: symbol("puzzlepiece.extension"))
            .replacingOccurrences(of: "{{iconAbout}}", with: symbol("info.circle"))
            .replacingOccurrences(of: "{{searchEngines}}", with: choices)
            .replacingOccurrences(of: "{{appearances}}", with: appearances)
            .replacingOccurrences(of: "{{faviconsChecked}}", with: BrowserSettings.showsFavicons ? " checked" : "")
            .replacingOccurrences(of: "{{downloadFolder}}", with: escape(folder))
            .replacingOccurrences(of: "{{passkeyStatus}}", with: escape(Passkeys.status))
            .replacingOccurrences(
                of: "{{passkeyAction}}",
                with: Passkeys.canRequestAccess
                    ? #"<a class="button" href="aero://settings/action/allow-passkeys">Allow…</a>"# : ""
            )
            .replacingOccurrences(
                of: "{{defaultStatus}}",
                with: escape(
                    BrowserSettings.isDefaultBrowser
                        ? "\(appName) is your default browser" : "\(appName) is not your default browser")
            )
            .replacingOccurrences(
                of: "{{defaultAction}}",
                with: BrowserSettings.isDefaultBrowser
                    ? "" : #"<a class="button" href="aero://settings/action/make-default">Make Default</a>"#
            )
            .replacingOccurrences(of: "{{version}}", with: escape(versionText))
    }

    /// Rasterizes an SF Symbol for WebKit while keeping the settings template free of copied icon paths.
    private static func symbol(_ name: String) -> String {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return "" }

        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let size = symbol.size
            let target = NSRect(
                x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                width: size.width, height: size.height)
            symbol.draw(in: target)
            return true
        }
        guard let data = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: data),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return "" }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
