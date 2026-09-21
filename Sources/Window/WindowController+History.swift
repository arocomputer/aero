import AppKit

/// Recently visited addresses are exposed through a native menu, without copying history into page scripts.
extension WindowController {
    @objc func showRecentHistory(_ sender: Any?) {
        let menu = NSMenu(title: "History")
        let entries = History.shared.recent()
        if entries.isEmpty {
            let item = menu.addItem(withTitle: "No saved history", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        for entry in entries {
            let title = entry.title.components(separatedBy: .newlines).joined(separator: " ")
            let label = title.isEmpty ? entry.display : "\(title.prefix(65)) · \(entry.url.host ?? entry.display)"
            let item = menu.addItem(withTitle: label, action: #selector(openHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Delete Browsing Data…", action: #selector(deleteBrowsingData(_:)), keyEquivalent: "")
        clear.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: strip.bounds.maxX - 14, y: strip.bounds.maxY + 4), in: strip)
    }

    @objc private func openHistoryEntry(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openExternal(url)
    }
}
