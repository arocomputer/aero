import Foundation
import SQLite3

/// A visited page as offered by the address field.
struct HistoryEntry: Equatable {
    let url: URL
    let display: String
    let title: String
}

/// Visited pages in a single SQLite table, queried on every keystroke for address suggestions.
/// Use from the main thread only.
final class History {
    /// The user's history, stored under the bundle identifier so it survives a rename of the app.
    static let shared: History = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "browser-dev")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return History(path: directory.appendingPathComponent("history.sqlite").path)
    }()

    private var db: OpaquePointer?

    /// Opens (creating if needed) the database at `path`; pass ":memory:" for a throwaway store.
    init(path: String) {
        sqlite3_open(path, &db)
        // Writes happen on the main thread while a page loads. A write-ahead log with relaxed syncing
        // keeps each one to a fraction of a millisecond instead of a wait for the disk.
        run("PRAGMA journal_mode = WAL")
        run("PRAGMA synchronous = NORMAL")
        run(
            """
            CREATE TABLE IF NOT EXISTS pages(
                url TEXT PRIMARY KEY, display TEXT NOT NULL, title TEXT NOT NULL,
                visits INTEGER NOT NULL, last_visit REAL NOT NULL)
            """)
    }

    deinit { sqlite3_close(db) }

    /// Counts a visit to an http(s) page. Search result pages are skipped so they don't crowd out real sites.
    func visit(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !AddressInput.isSearchURL(url) else { return }
        run(
            """
            INSERT INTO pages(url, display, title, visits, last_visit) VALUES(?1, ?2, '', 1, ?3)
            ON CONFLICT(url) DO UPDATE SET visits = visits + 1, last_visit = ?3
            """, [url.absoluteString, AddressInput.display(for: url), Date().timeIntervalSince1970])
    }

    /// Stores the title of an already visited page.
    func setTitle(_ title: String, for url: URL) {
        run("UPDATE pages SET title = ?1 WHERE url = ?2", [title, url.absoluteString])
    }

    /// Pages whose address or title contains `text`. Addresses that start with it come first, so the
    /// first entry is the inline-completion candidate; within each group the most visited wins.
    func suggestions(for text: String, limit: Int = 5) -> [HistoryEntry] {
        let query = AddressInput.stripped(text.trimmingCharacters(in: .whitespaces))
        if query.isEmpty { return [] }
        let escaped =
            query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")

        var entries: [HistoryEntry] = []
        run(
            """
            SELECT url, display, title FROM pages
            WHERE display LIKE ?2 ESCAPE '\\' OR title LIKE ?2 ESCAPE '\\'
            ORDER BY (display LIKE ?1 ESCAPE '\\') DESC, visits DESC, last_visit DESC
            LIMIT ?3
            """, [escaped + "%", "%" + escaped + "%", limit]
        ) { row in
            let column = { String(cString: sqlite3_column_text(row, $0)) }
            if let url = URL(string: column(0)) {
                entries.append(HistoryEntry(url: url, display: column(1), title: column(2)))
            }
        }
        return entries
    }

    /// Runs one statement with positional bindings (String, Double or Int), calling `onRow` per result row.
    private func run(_ sql: String, _ bindings: [Any] = [], onRow: ((OpaquePointer) -> Void)? = nil) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            case let number as Double: sqlite3_bind_double(statement, position, number)
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            default: preconditionFailure("unsupported binding \(value)")
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW { onRow?(statement) }
    }
}
