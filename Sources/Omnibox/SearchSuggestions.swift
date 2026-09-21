import Foundation

/// Optional Google suggestions use an ephemeral session. Addresses and private-tab text are not sent.
enum SearchSuggestions {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 4
        return URLSession(configuration: configuration)
    }()

    static func fetch(_ query: String) async -> [HistoryEntry] {
        guard UserDefaults.standard.bool(forKey: "RemoteSuggestions"), Settings.searchEngine == .google, CustomSearch.selected == nil,
            query.count >= 2, query.count <= 200, !query.contains(where: { ":/@?=".contains($0) }),
            AddressInput.url(for: query) == SearchEngine.google.url(for: query)
        else { return [] }
        var url = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        url.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: query)]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        do {
            var request = URLRequest(url: url.url!)
            if Settings.globalPrivacyControl { request.setValue("1", forHTTPHeaderField: "Sec-GPC") }
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200, data.count < 65_536,
                let result = try JSONSerialization.jsonObject(with: data) as? [Any], result.count > 1,
                let suggestions = result[1] as? [String]
            else { return [] }
            return suggestions.prefix(5).map { HistoryEntry(url: SearchEngine.google.url(for: $0), display: $0, title: "Search Google") }
        } catch { return [] }
    }
}
