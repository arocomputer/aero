import Foundation

/// Local bookmarks with named folders. Explicitly saved links are independent of browsing history.
final class Bookmarks {
    struct Entry: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var title: String
        var url: URL
        var folder: String
    }
    static let shared = Bookmarks(file: AppPaths.support.appendingPathComponent("bookmarks.json"))
    private let file: URL
    private(set) var entries: [Entry]

    init(file: URL) {
        self.file = file
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
    }

    func save(_ entry: Entry) throws {
        guard AddressInput.isWeb(entry.url), entry.url.host?.isEmpty == false else { return }
        var updated = entries
        if let index = updated.firstIndex(where: { $0.id == entry.id }) { updated[index] = entry } else { updated.append(entry) }
        try persist(updated)
    }

    func remove(_ id: UUID) throws { try persist(entries.filter { $0.id != id }) }

    /// Imports the standard Netscape bookmark HTML exported by Safari, Chrome and Firefox.
    func importHTML(_ html: String) throws -> Int {
        guard html.utf8.count <= 16_777_216 else {
            throw NSError(domain: "Bookmarks", code: 2, userInfo: [NSLocalizedDescriptionKey: "The bookmark file exceeds 16 MB."])
        }
        let parser = try NSRegularExpression(
            pattern: #"(?is)<h3\b[^>]*>(.*?)</h3>|<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>|<(/?)dl\b[^>]*>"#)
        var folders: [String] = []
        var pendingFolder: String?
        var additions: [Entry] = []
        let source = html as NSString
        for match in parser.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            if match.range(at: 1).location != NSNotFound {
                pendingFolder = Self.unescape(source.substring(with: match.range(at: 1)))
            } else if match.range(at: 2).location != NSNotFound {
                let address = Self.unescape(source.substring(with: match.range(at: 2)))
                let folder = folders.filter { !$0.isEmpty }.joined(separator: " / ")
                let entryFolder = folder.isEmpty ? "Imported" : folder
                let title = Self.unescape(source.substring(with: match.range(at: 3)))
                guard let url = URL(string: address), AddressInput.isWeb(url), url.host?.isEmpty == false,
                    !entries.contains(where: { $0.url == url && $0.folder == entryFolder && $0.title == title }),
                    !additions.contains(where: { $0.url == url && $0.folder == entryFolder && $0.title == title })
                else { continue }
                additions.append(Entry(title: title, url: url, folder: entryFolder))
            } else if source.substring(with: match.range(at: 4)) == "/" {
                if !folders.isEmpty { folders.removeLast() }
            } else {
                guard folders.count < 64 else {
                    throw NSError(
                        domain: "Bookmarks", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "The bookmark file contains too many nested folders."])
                }
                folders.append(pendingFolder ?? "")
                pendingFolder = nil
            }
        }
        try persist(entries + additions)
        return additions.count
    }

    func exportHTML() -> String {
        func write(_ path: [String]) -> String {
            var html = "<DL><p>\n"
            let members = entries.filter { $0.folder.components(separatedBy: " / ").starts(with: path) }
            for entry in members where entry.folder.components(separatedBy: " / ") == path {
                html += "<DT><A HREF=\"\(BrowserPage.escape(entry.url.absoluteString))\">\(BrowserPage.escape(entry.title))</A>\n"
            }
            let children = Set(
                members.compactMap { entry -> String? in
                    let parts = entry.folder.components(separatedBy: " / ")
                    return parts.count > path.count ? parts[path.count] : nil
                })
            for child in children.sorted() { html += "<DT><H3>\(BrowserPage.escape(child))</H3>\n" + write(path + [child]) }
            return html + "</DL><p>\n"
        }
        return
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n"
            + write([])
    }

    private func persist(_ updated: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        entries = updated
    }

    private static func unescape(_ text: String) -> String {
        let text = text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(
            of: "&nbsp;", with: "\u{00a0}"
        )
        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        let decoded = NSMutableString(string: text)
        let pattern = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let code = (text as NSString).substring(with: match.range(at: 1))
            let number = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let number, let scalar = UnicodeScalar(number) { decoded.replaceCharacters(in: match.range, with: String(scalar)) }
        }
        return (decoded as String).replacingOccurrences(of: "&amp;", with: "&")
    }
}
