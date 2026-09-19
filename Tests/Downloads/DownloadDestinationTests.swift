import Foundation
import Testing
@testable import Browser

@Test func downloadDestinationKeepsTheSuggestedNameWhenItIsUnused() {
    let directory = URL(fileURLWithPath: "/Downloads", isDirectory: true)
    let url = DownloadDestination.availableURL(in: directory, suggestedFilename: "report.pdf") { _ in false }
    #expect(url.lastPathComponent == "report.pdf")
}

@Test func downloadDestinationAddsANumberWithoutLosingTheExtension() {
    let directory = URL(fileURLWithPath: "/Downloads", isDirectory: true)
    let existing: Set = ["report.pdf", "report 2.pdf"]
    let url = DownloadDestination.availableURL(in: directory, suggestedFilename: "report.pdf", fileExists: existing.contains)
    #expect(url.lastPathComponent == "report 3.pdf")
}

@Test func downloadDestinationStripsDirectoriesFromServerInput() {
    let directory = URL(fileURLWithPath: "/Downloads", isDirectory: true)
    let url = DownloadDestination.availableURL(in: directory, suggestedFilename: "../../private.txt") { _ in false }
    #expect(url.lastPathComponent == "private.txt")
}
