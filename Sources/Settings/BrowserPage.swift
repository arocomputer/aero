import Foundation
import AppKit

/// Renders bundled browser pages without reinterpreting placeholder text inside user-supplied values.
enum BrowserPage {
    @MainActor private static var symbols: [String: String] = [:]

    /// Renders Apple's system symbols once for local pages without a second set of custom glyphs.
    @MainActor static func symbol(_ name: String) -> String {
        if let stored = symbols[name] { return stored }
        let image = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { bounds in
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemGray]))?.draw(in: bounds.insetBy(dx: 2, dy: 2))
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return "" }
        let result = "data:image/png;base64," + png.base64EncodedString()
        symbols[name] = result
        return result
    }
    static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    static func render(_ name: String, values: [String: String]) -> String {
        var values = values
        values["styles"] = resource("BrowserPage", "css")
        values["script"] = (name == "Library" ? "" : resource("BrowserPage", "js")) + "\n" + resource(name, "js")
        let template = resource(name, "html")
        let pattern = try! NSRegularExpression(pattern: #"\{\{([A-Za-z]+)\}\}"#)
        let result = NSMutableString(string: template)
        for match in pattern.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let key = (template as NSString).substring(with: match.range(at: 1))
            result.replaceCharacters(in: match.range, with: values[key] ?? "")
        }
        return result as String
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Encodes action parameters separately from HTML attributes.
    static func action(_ host: String, _ action: String, parameters: [String: String] = [:]) -> String {
        var url = URLComponents()
        url.scheme = "aero"
        url.host = host
        url.path = "/action/" + action
        if !parameters.isEmpty {
            url.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return escape(url.string!)
    }
}
