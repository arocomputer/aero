import CryptoKit
import Foundation

/// A bounded, dated list of tracker domains. Network copies must verify against the publisher's key.
struct ProtectionList {
    let domains: [String]
    let version: String

    static func parse(_ data: Data) throws -> ProtectionList {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
            let dateLine = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("# Retrieved ") })
        else { throw invalid("The protection list is missing its version or exceeds the size limit.") }
        let version = String(dateLine.dropFirst(12).prefix(10))
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        format.isLenient = false
        guard version.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, format.date(from: version) != nil else {
            throw invalid("The protection list has an invalid version.")
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard (500...20_000).contains(lines.count) else { throw invalid("The protection list has an unexpected number of entries.") }
        let pattern = #"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#
        guard lines.allSatisfy({ $0.utf8.count <= 253 && $0.range(of: pattern, options: .regularExpression) != nil }) else {
            throw invalid("The protection list contains invalid domains.")
        }
        let domains = Set(lines).sorted()
        guard domains.count >= 500 else { throw invalid("The protection list contains too few distinct domains.") }
        return ProtectionList(domains: domains, version: version)
    }

    static func verified(_ data: Data, signature: Data, key: Data) throws -> ProtectionList {
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
        guard publicKey.isValidSignature(signature, for: data) else {
            throw invalid("The protection-list signature is invalid. The current list was kept.")
        }
        return try parse(data)
    }

    static var publisherKey: Data? {
        (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String).flatMap { Data(base64Encoded: $0) }
    }
    static var cacheURL: URL { AppPaths.support.appendingPathComponent("protection-list.json") }
    struct Cache: Codable { let content: Data; let signature: Data }

    static func current() throws -> ProtectionList {
        let url = Bundle.module.url(forResource: "Trackers", withExtension: "txt")!
        let bundled = try parse(Data(contentsOf: url))
        if let key = publisherKey, let data = try? Data(contentsOf: cacheURL),
            let cache = try? JSONDecoder().decode(Cache.self, from: data),
            let saved = try? verified(cache.content, signature: cache.signature, key: key), saved.version >= bundled.version
        {
            return saved
        }
        return bundled
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "ProtectionList", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Fetches signed list updates independently of app releases. No visited addresses are included in requests.
@MainActor final class ProtectionUpdates {
    static let shared = ProtectionUpdates()
    private(set) var checking = false
    private(set) var message: String?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    var configured: Bool {
        guard let address = Bundle.main.object(forInfoDictionaryKey: "BrowserProtectionListURL") as? String,
            let url = URL(string: address), url.scheme == "https", ProtectionList.publisherKey?.count == 32
        else { return false }
        return true
    }

    func checkIfDue() async {
        guard configured, UserDefaults.standard.object(forKey: "ProtectionListAutomaticUpdates") as? Bool ?? true else { return }
        let last = UserDefaults.standard.object(forKey: "ProtectionListLastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 86_400 else { return }
        try? await check()
    }

    func check() async throws {
        guard configured, !checking,
            let address = Bundle.main.object(forInfoDictionaryKey: "BrowserProtectionListURL") as? String,
            let url = URL(string: address), let key = ProtectionList.publisherKey
        else {
            throw NSError(
                domain: "ProtectionList", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Signed protection updates are not configured for this build."])
        }
        checking = true
        defer { checking = false }
        UserDefaults.standard.set(Date(), forKey: "ProtectionListLastCheck")
        do {
            let content = try await fetch(url, limit: 1_048_576)
            let signatureText = try await fetch(URL(string: address + ".sig")!, limit: 512)
            guard
                let signature = Data(
                    base64Encoded: String(decoding: signatureText, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                throw NSError(
                    domain: "ProtectionList", code: 3, userInfo: [NSLocalizedDescriptionKey: "The protection-list signature is malformed."])
            }
            let list = try ProtectionList.verified(content, signature: signature, key: key)
            let current = try ProtectionList.current()
            guard list.version >= current.version else {
                throw NSError(
                    domain: "ProtectionList", code: 4, userInfo: [NSLocalizedDescriptionKey: "An older protection list was rejected."])
            }
            if list.version != current.version || list.domains != current.domains {
                try await TrackerProtection.shared.replaceDomains(list.domains) {
                    let data = try JSONEncoder().encode(ProtectionList.Cache(content: content, signature: signature))
                    try data.write(to: ProtectionList.cacheURL, options: .atomic)
                }
            }
            message = "Protection list \(list.version) is current."
            UserDefaults.standard.set(Date(), forKey: "ProtectionListLastSuccess")
        } catch {
            message = "The current list was kept. " + error.localizedDescription
            throw error
        }
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if Settings.globalPrivacyControl { request.setValue("1", forHTTPHeaderField: "Sec-GPC") }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= limit else {
            bytes.task.cancel()
            throw NSError(
                domain: "ProtectionList", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The protection server returned an invalid response."])
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { bytes.task.cancel(); throw NSError(domain: "ProtectionList", code: 6) }
            data.append(byte)
        }
        return data
    }
}
