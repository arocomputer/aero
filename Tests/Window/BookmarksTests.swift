import Foundation
import Testing
@testable import Browser

@Test func bookmarksRoundTripNestedFoldersAndEscapedAddresses() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bookmarks = Bookmarks(file: root.appendingPathComponent("first.json"))
    let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1><DL><p>
        <DT><H3>Research &amp; notes</H3><DL><p>
        <DT><H3>Web</H3><DL><p>
        <DT><A HREF="https://example.test/?a=1&amp;b=2">A &#x26; B</A>
        </DL><p><DT><A HREF="https://second.example.test/">Second</A></DL><p>
        <DT><A HREF="javascript:alert(1)">Invalid</A></DL><p>
        """
    #expect(try bookmarks.importHTML(html) == 2)
    #expect(bookmarks.entries.map(\.folder) == ["Research & notes / Web", "Research & notes"])
    #expect(bookmarks.entries.first?.title == "A & B")
    let imported = Bookmarks(file: root.appendingPathComponent("second.json"))
    #expect(try imported.importHTML(bookmarks.exportHTML()) == 2)
    #expect(Set(imported.entries.map(\.url)) == Set(bookmarks.entries.map(\.url)))
    #expect(Set(imported.entries.map(\.folder)) == Set(bookmarks.entries.map(\.folder)))
    #expect(try imported.importHTML(bookmarks.exportHTML()) == 0)
}
