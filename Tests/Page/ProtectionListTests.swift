import CryptoKit
import Foundation
import Testing
@testable import Browser

@Test func signedProtectionListsRejectTamperingAndMalformedDomains() throws {
    let key = Curve25519.Signing.PrivateKey()
    let domains = (0..<500).map { "tracker\($0).example.test" }.joined(separator: "\n")
    let data = Data(("# Retrieved 2026-09-20\n" + domains + "\n").utf8)
    let signature = try key.signature(for: data)
    let list = try ProtectionList.verified(data, signature: signature, key: key.publicKey.rawRepresentation)
    #expect(list.domains.count == 500)
    #expect(list.version == "2026-09-20")
    #expect(throws: (any Error).self) {
        try ProtectionList.verified(data + Data("changed".utf8), signature: signature, key: key.publicKey.rawRepresentation)
    }
    let invalid = data + Data("https://not-a-domain.example/\n".utf8)
    #expect(throws: (any Error).self) {
        try ProtectionList.verified(invalid, signature: key.signature(for: invalid), key: key.publicKey.rawRepresentation)
    }
}
