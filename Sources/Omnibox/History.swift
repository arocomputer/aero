import Foundation
import SQLite3

/// A visited page as offered by the address field.
struct HistoryEntry: Equatable {
    let url: URL
    let display: String
    let title: String
}

/// One recorded navigation. Older databases contribute their last-known visit for each address.
struct HistoryVisit {
    let id: Int
    let url: URL
    let title: String
    let date: Date
}

/// Visited pages in a single SQLite table, queried on every keystroke for address suggestions.
/// Use from the main thread only.
final class History {
    /// The user's history, stored under the bundle identifier so it survives a rename of the app.
    static let shared = History(path: AppPaths.support.appendingPathComponent("history.sqlite").path, retention: { Settings.historyDays })

    private var db: OpaquePointer?
    private let retention: () -> Int
    private var lastPrune: (days: Int, date: Date)?

    /// Opens (creating if needed) the database at `path`; pass ":memory:" for a throwaway store.
    init(path: String, retention: @escaping () -> Int = { 0 }) {
        self.retention = retention
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
        run("BEGIN IMMEDIATE")
        run(
            "CREATE TABLE IF NOT EXISTS visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, visited REAL NOT NULL, weight INTEGER NOT NULL DEFAULT 1)"
        )
        run("CREATE INDEX IF NOT EXISTS visits_address ON visits(url, visited)")
        run("CREATE INDEX IF NOT EXISTS visits_time ON visits(visited)")
        run("CREATE TABLE IF NOT EXISTS history_metadata(key TEXT PRIMARY KEY)")
        run(
            "INSERT INTO visits(url, visited, weight) SELECT url, last_visit, visits FROM pages WHERE NOT EXISTS (SELECT 1 FROM history_metadata WHERE key = 'visits-migrated')"
        )
        run("INSERT OR IGNORE INTO history_metadata(key) VALUES('visits-migrated')")
        run("COMMIT")
    }

    deinit { sqlite3_close(db) }

    /// Counts a visit to an http(s) page. Search result pages are skipped so they don't crowd out real sites.
    func visit(_ url: URL, at date: Date = Date()) {
        prune(now: date)
        guard retention() != -1 else { return }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !AddressInput.isSearchURL(url) else { return }
        run(
            """
            INSERT INTO pages(url, display, title, visits, last_visit) VALUES(?1, ?2, '', 1, ?3)
            ON CONFLICT(url) DO UPDATE SET visits = visits + 1, last_visit = ?3
            """, [url.absoluteString, AddressInput.display(for: url), date.timeIntervalSince1970])
        run("INSERT INTO visits(url, visited) VALUES(?1, ?2)", [url.absoluteString, date.timeIntervalSince1970])
    }

    /// Stores the title of an already visited page.
    func setTitle(_ title: String, for url: URL) {
        run("UPDATE pages SET title = ?1 WHERE url = ?2", [title, url.absoluteString])
    }

    /// Pages whose address or title contains `text`. Addresses that start with it come first, so the
    /// first entry is the inline-completion candidate; within each group the most visited wins.
    func suggestions(for text: String, limit: Int = 5) -> [HistoryEntry] {
        prune()
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

    /// Recently visited addresses for the browser menu, newest first and subject to retention.
    func recent(limit: Int = 30) -> [HistoryEntry] {
        prune()
        var entries: [HistoryEntry] = []
        run("SELECT url, display, title FROM pages ORDER BY last_visit DESC LIMIT ?1", [max(0, limit)]) { row in
            let column = { String(cString: sqlite3_column_text(row, $0)) }
            if let url = URL(string: column(0)) {
                entries.append(HistoryEntry(url: url, display: column(1), title: column(2)))
            }
        }
        return entries
    }

    /// Removes pages last visited in the requested period, including their titles and visit counts.
    func clear(since date: Date = .distantPast) {
        run("BEGIN IMMEDIATE")
        run("DELETE FROM visits WHERE visited >= ?1", [date.timeIntervalSince1970])
        rebuildSummaries()
        run("COMMIT")
    }

    /// Applies retention at most daily, or immediately when the selected period changes.
    func prune(now: Date = Date()) {
        let days = retention()
        if let lastPrune, lastPrune.days == days, now.timeIntervalSince(lastPrune.date) < 86_400 { return }
        lastPrune = (days, now)
        if days == -1 {
            clear()
        } else if days > 0 {
            run("DELETE FROM visits WHERE visited < ?1", [now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970])
            rebuildSummaries()
        }
    }

    /// Searches the complete visit log rather than only the currently displayed rows.
    func visits(matching query: String = "", limit: Int = 500) -> [HistoryVisit] {
        prune()
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(
            of: "_", with: "\\_")
        var visits: [HistoryVisit] = []
        run(
            """
            SELECT v.id, v.url, p.title, v.visited FROM visits v JOIN pages p ON p.url = v.url
            WHERE v.url LIKE ?1 ESCAPE '\\' OR p.title LIKE ?1 ESCAPE '\\'
            ORDER BY v.visited DESC, v.id DESC LIMIT ?2
            """, ["%" + escaped + "%", max(0, limit)]
        ) { row in
            guard let url = URL(string: String(cString: sqlite3_column_text(row, 1))) else { return }
            visits.append(
                HistoryVisit(
                    id: Int(sqlite3_column_int64(row, 0)), url: url,
                    title: String(cString: sqlite3_column_text(row, 2)), date: Date(timeIntervalSince1970: sqlite3_column_double(row, 3))))
        }
        return visits
    }

    func removeVisit(_ id: Int) {
        run("DELETE FROM visits WHERE id = ?1", [id])
        rebuildSummaries()
    }

    private func rebuildSummaries() {
        run("DELETE FROM pages WHERE NOT EXISTS (SELECT 1 FROM visits WHERE visits.url = pages.url)")
        run(
            "UPDATE pages SET visits = (SELECT SUM(weight) FROM visits WHERE visits.url = pages.url), last_visit = (SELECT MAX(visited) FROM visits WHERE visits.url = pages.url)"
        )
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
