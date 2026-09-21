import Foundation
import Testing
@testable import Browser

@Test func replacingADownloadKeepsTheOriginalUntilACompleteReplacementExists() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("existing.txt")
    let staged = directory.appendingPathComponent("staged.txt")
    try Data("original".utf8).write(to: destination)
    #expect(throws: (any Error).self) { try DownloadPlacement.commit(staged: staged, to: destination) }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    try Data("replacement".utf8).write(to: staged)
    try DownloadPlacement.commit(staged: staged, to: destination, allowReplacement: true)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "replacement")
    #expect(!FileManager.default.fileExists(atPath: staged.path))
}

@Test func aDownloadCannotReplaceAnUnapprovedDestinationCollision() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("destination.txt")
    let staged = directory.appendingPathComponent("staged.txt")
    try Data("other work".utf8).write(to: destination)
    try Data("download".utf8).write(to: staged)
    #expect(throws: (any Error).self) { try DownloadPlacement.commit(staged: staged, to: destination) }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "other work")
    #expect(FileManager.default.fileExists(atPath: staged.path))
}
