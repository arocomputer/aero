import Foundation

/// Converts between what the user types in the address field and real URLs.
enum AddressInput {
    /// The URL to load for typed text: an address if it looks like one, otherwise a web search.
    /// Returns nil for empty input.
    static func url(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.contains(where: \.isWhitespace) { return searchURL(for: text) }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            ["http", "https", "file", "about"].contains(scheme)
        {
            return url
        }
        if let scheme = defaultScheme(forAddress: text), let url = URL(string: "\(scheme)://\(text)") {
            return url
        }
        return searchURL(for: text)
    }

    static func searchURL(for query: String) -> URL {
        Settings.searchEngine.url(for: query)
    }

    /// True for the result pages `searchURL` produces, so they can be kept out of history.
    static func isSearchURL(_ url: URL) -> Bool {
        SearchEngine.allCases.contains { $0.owns(url) }
    }

    /// The short form shown in suggestions and the address field: no scheme, no "www.", no trailing slash.
    static func display(for url: URL) -> String {
        stripped(url.absoluteString)
    }

    /// Removes the scheme, "www." and a trailing slash from an address-like string.
    static func stripped(_ address: String) -> String {
        var text = Substring(address)
        for prefix in ["https://", "http://", "www."] where text.lowercased().hasPrefix(prefix) {
            text = text.dropFirst(prefix.count)
        }
        if text.hasSuffix("/") { text = text.dropLast() }
        return String(text)
    }

    /// "https" or "http" when the text starts with something host-shaped (a dotted name, localhost,
    /// or an IPv4 address, optionally with a port), nil when it should be treated as a search.
    private static func defaultScheme(forAddress text: String) -> String? {
        let hostAndPort = text.prefix { !"/?#".contains($0) }
        let parts = hostAndPort.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, !host.isEmpty else { return nil }
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(\.isNumber) { return nil }

        if host.lowercased() == "localhost" { return "http" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return "http" }
        let topLevel = labels[labels.count - 1]
        return topLevel.count >= 2 && topLevel.allSatisfy(\.isLetter) ? "https" : nil
    }
}
