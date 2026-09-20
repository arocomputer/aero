import AppKit

/// The downloads button's menu.
extension WindowController {
    /// Shows current-session downloads from newest to oldest. Completed files open in Finder;
    /// running downloads can be cancelled without keeping their original tab alive.
    func showDownloads(relativeTo view: NSView) {
        let menu = NSMenu(title: "Downloads")
        for item in downloads.items {
            switch item.state {
            case .running:
                let percent = Int((item.progress * 100).rounded())
                let status = NSMenuItem(title: "\(item.filename) (\(percent)%)", action: nil, keyEquivalent: "")
                status.isEnabled = false
                menu.addItem(status)
                let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelDownload(_:)), keyEquivalent: "")
                cancel.target = self
                cancel.representedObject = item
                menu.addItem(cancel)
            case .finished:
                let reveal = NSMenuItem(title: item.filename, action: #selector(revealDownload(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = item
                menu.addItem(reveal)
            case let .failed(message):
                let failed = NSMenuItem(title: "\(item.filename): \(message)", action: nil, keyEquivalent: "")
                failed.isEnabled = false
                menu.addItem(failed)
            case .cancelled:
                let cancelled = NSMenuItem(title: "\(item.filename) (Cancelled)", action: nil, keyEquivalent: "")
                cancelled.isEnabled = false
                menu.addItem(cancelled)
            }
            if item !== downloads.items.last { menu.addItem(.separator()) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX, y: view.bounds.maxY + 4), in: view)
    }

    func downloadsDidChange() {
        strip.showsDownloads = !downloads.items.isEmpty
    }

    @objc private func cancelDownload(_ sender: NSMenuItem) {
        (sender.representedObject as? DownloadItem)?.cancel()
    }

    @objc private func revealDownload(_ sender: NSMenuItem) {
        (sender.representedObject as? DownloadItem)?.reveal()
    }
}
