import Foundation
import WebKit

/// Presents local records as escaped HTML. Navigation actions are handled only by their owning origin.
@MainActor enum LibraryPage {
    static func siteData(_ records: [WKWebsiteDataRecord], url: URL) -> String {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
        let rows = records.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
            .sorted { $0.displayName < $1.displayName }.map { record in
                """
                <div class="setting-row">
                  <div class="setting-copy"><span class="setting-title">\(BrowserPage.escape(record.displayName))</span><p>\(BrowserPage.escape(record.dataTypes.sorted().map { $0.replacingOccurrences(of: "WKWebsiteDataType", with: "") }.joined(separator: ", ")))</p></div>
                  <a class="button danger" href="\(BrowserPage.action("site-data", "remove", parameters: ["site": record.displayName]))">Remove…</a>
                </div>
                """
            }.joined(separator: "\n")
        return BrowserPage.render(
            "Library",
            values: [
                "title": "Website data", "query": BrowserPage.escape(query),
                "description":
                    "Cookies and storage for this browsing session. Removing a website also removes data for its subdomains and may sign you out.",
                "rows": rows.isEmpty ? "<p class=\"empty\">No matching website data.</p>" : rows,
                "actions": "<a class=\"button\" href=\"aero://settings#websites\">Site settings</a>",
            ])
    }
    static func html(for url: URL, downloads: Downloads? = nil) -> String {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
        let host = url.host ?? "history"
        let title = host.capitalized
        var rows = ""
        var actions = ""
        var description = ""
        if host == "history" {
            description = "Individual visits, newest first. Search covers all saved visits; up to 500 results are shown."
            for visit in History.shared.visits(matching: query) {
                rows += row(
                    title: visit.title.isEmpty ? AddressInput.display(for: visit.url) : visit.title,
                    detail: DateFormatter.localizedString(from: visit.date, dateStyle: .medium, timeStyle: .short) + " · "
                        + AddressInput.display(for: visit.url),
                    url: visit.url,
                    action: BrowserPage.action("history", "remove", parameters: ["id": String(visit.id)]), actionTitle: "Remove")
            }
            actions = "<a class=\"button\" href=\"aero://history/action/clear\">Delete browsing data…</a>"
        } else if host == "bookmarks" {
            description = "Links you chose to save, organized by folder."
            actions =
                "<a class=\"button\" href=\"aero://bookmarks/action/add\">Add bookmark…</a><a class=\"button\" href=\"aero://bookmarks/action/import\">Import…</a><a class=\"button\" href=\"aero://bookmarks/action/export\">Export…</a>"
            for entry in Bookmarks.shared.entries
            where query.isEmpty || (entry.title + entry.url.absoluteString + entry.folder).localizedCaseInsensitiveContains(query) {
                rows += row(
                    title: entry.title, detail: entry.folder + " · " + AddressInput.display(for: entry.url), url: entry.url,
                    action: BrowserPage.action("bookmarks", "edit", parameters: ["id": entry.id.uuidString]), actionTitle: "Edit…")
            }
        } else if host == "downloads" {
            description =
                "Transfers continue when ordinary windows close. Paused downloads can resume when the server supports it. Removing a record does not delete a saved file."
            let manager = downloads ?? .shared
            for item in manager.items
            where query.isEmpty || (item.filename + (item.record.source?.host ?? "")).localizedCaseInsensitiveContains(query) {
                var buttons = ""
                let add = { (command: String, title: String) in
                    "<a class=\"button\" href=\"\(BrowserPage.action("downloads", command, parameters: ["id": item.id.uuidString]))\">\(title)</a>"
                }
                switch item.state {
                case .running: buttons = add("pause", "Pause") + add("cancel", "Cancel")
                case .finished: buttons = add("reveal", "Show in Finder") + add("remove", "Remove record")
                case .paused, .failed, .cancelled:
                    if item.record.source != nil || item.canResume {
                        buttons += add("retry", item.record.completedTransfer == true ? "Save…" : item.canResume ? "Resume" : "Retry")
                    }
                    buttons += add("remove", "Remove record")
                }
                let status =
                    item.state == .running
                    ? "\(Int((item.progress * 100).rounded()))%" : item.record.failure ?? item.state.rawValue.capitalized
                rows += """
                    <div class="setting-row"><div class="setting-copy"><span class="setting-title">\(BrowserPage.escape(item.filename))</span><p>\(BrowserPage.escape(status)) · \(BrowserPage.escape(item.record.source?.host ?? "Download"))</p></div><div class="controls">\(buttons)</div></div>
                    """
            }
        }
        return BrowserPage.render(
            "Library",
            values: [
                "title": title, "query": BrowserPage.escape(query), "description": BrowserPage.escape(description),
                "actions": actions, "rows": rows.isEmpty ? "<p class=\"empty\">No matching records.</p>" : rows,
            ])
    }

    private static func row(title: String, detail: String, url: URL, action: String, actionTitle: String) -> String {
        """
        <div class="setting-row">
          <div class="setting-copy"><a href="\(BrowserPage.escape(url.absoluteString))">\(BrowserPage.escape(title))</a><p>\(BrowserPage.escape(detail))</p></div>
          <a class="button" href="\(action)">\(actionTitle)</a>
        </div>
        """
    }
}
