import Foundation

/// User-defined search templates and keyword shortcuts. Templates are validated before storage.
enum CustomSearch {
    struct Engine: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var shortcut: String
        var template: String

        func url(for query: String) -> URL? {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=#?%"))
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
        }
        var isValid: Bool {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, template.contains("%s"),
                let url = url(for: "test"), AddressInput.isWeb(url), url.host?.isEmpty == false,
                url.user == nil, url.password == nil
            else { return false }
            return !shortcut.contains(where: \.isWhitespace)
        }
    }

    static var engines: [Engine] {
        guard let data = UserDefaults.standard.data(forKey: "CustomSearchEngines") else { return [] }
        return ((try? JSONDecoder().decode([Engine].self, from: data)) ?? []).filter(\.isValid)
    }
    static var selected: Engine? {
        let id = UserDefaults.standard.string(forKey: "CustomSearchDefault")
        return engines.first { $0.id.uuidString == id }
    }
    static var name: String { selected?.name ?? Settings.searchEngine.name }
    static func name(for text: String) -> String {
        let pieces = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if pieces.count == 2,
            let engine = engines.first(where: { !$0.shortcut.isEmpty && $0.shortcut.lowercased() == pieces[0].lowercased() })
        {
            return engine.name
        }
        return name
    }

    static func search(_ text: String) -> URL {
        let pieces = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if pieces.count == 2,
            let engine = engines.first(where: { !$0.shortcut.isEmpty && $0.shortcut.lowercased() == pieces[0].lowercased() }),
            let url = engine.url(for: String(pieces[1]))
        {
            return url
        }
        return selected?.url(for: text) ?? Settings.searchEngine.url(for: text)
    }

    static func owns(_ url: URL) -> Bool {
        engines.contains { engine in
            guard let sample = engine.url(for: "BROWSERSEARCHMARKER") else { return false }
            let pattern =
                "^"
                + NSRegularExpression.escapedPattern(for: sample.absoluteString).replacingOccurrences(of: "BROWSERSEARCHMARKER", with: ".*")
                + "(?:[&#].*)?$"
            return url.absoluteString.range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func save(_ engine: Engine) throws {
        guard engine.isValid else {
            throw NSError(
                domain: "Search", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Enter a name and an HTTP or HTTPS search URL containing %s. Shortcuts cannot contain spaces."
                ])
        }
        var all = engines.filter { $0.id != engine.id }
        if !engine.shortcut.isEmpty, all.contains(where: { $0.shortcut.lowercased() == engine.shortcut.lowercased() }) {
            throw NSError(domain: "Search", code: 2, userInfo: [NSLocalizedDescriptionKey: "That search shortcut is already in use."])
        }
        all.append(engine)
        UserDefaults.standard.set(try JSONEncoder().encode(all), forKey: "CustomSearchEngines")
    }

    static func remove(_ id: UUID) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(engines.filter { $0.id != id }), forKey: "CustomSearchEngines")
        if UserDefaults.standard.string(forKey: "CustomSearchDefault") == id.uuidString {
            UserDefaults.standard.removeObject(forKey: "CustomSearchDefault")
        }
    }
}
