import AppKit

/// The downloads button's menu.
extension WindowController {
    @objc func openDownloads(_ sender: Any?) { openLibrary("downloads") }

    /// Shows recent downloads, with transfer controls and a link to the complete library.
    func showDownloads(relativeTo view: NSView) {
        let menu = NSMenu(title: "Downloads")
        if downloads.items.isEmpty {
            let item = menu.addItem(withTitle: "No downloads", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        let recent = Array(downloads.items.prefix(20))
        for item in recent {
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
                let pause = menu.addItem(withTitle: "Pause", action: #selector(pauseDownload(_:)), keyEquivalent: "")
                pause.target = self
                pause.representedObject = item
            case .finished:
                let reveal = NSMenuItem(title: item.filename, action: #selector(revealDownload(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = item
                menu.addItem(reveal)
            case .failed, .paused:
                let failed = NSMenuItem(title: "\(item.filename): \(item.record.failure ?? "Paused")", action: nil, keyEquivalent: "")
                failed.isEnabled = false
                menu.addItem(failed)
                let retry = menu.addItem(
                    withTitle: item.canResume ? "Resume" : "Retry", action: #selector(retryDownload(_:)), keyEquivalent: "")
                retry.target = self
                retry.representedObject = item
            case .cancelled:
                let cancelled = NSMenuItem(title: "\(item.filename) (Cancelled)", action: nil, keyEquivalent: "")
                cancelled.isEnabled = false
                menu.addItem(cancelled)
            }
            if item !== recent.last { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let folder = menu.addItem(withTitle: "Open Download Folder", action: #selector(openDownloadFolder(_:)), keyEquivalent: "")
        folder.target = self
        let all = menu.addItem(withTitle: "Show All Downloads", action: #selector(openDownloads(_:)), keyEquivalent: "")
        all.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX, y: view.bounds.maxY + 4), in: view)
    }

    func downloadsDidChange() {
        strip.showsDownloads = !downloads.items.isEmpty
    }

    @objc private func cancelDownload(_ sender: NSMenuItem) {
        (sender.representedObject as? DownloadItem)?.cancel()
    }
    @objc private func pauseDownload(_ sender: NSMenuItem) { (sender.representedObject as? DownloadItem)?.pause() }
    @objc private func retryDownload(_ sender: NSMenuItem) {
        if let view = active?.webView { (sender.representedObject as? DownloadItem)?.restart(in: view) }
    }

    @objc private func revealDownload(_ sender: NSMenuItem) {
        (sender.representedObject as? DownloadItem)?.reveal()
    }

    @objc private func openDownloadFolder(_ sender: Any?) { NSWorkspace.shared.open(Settings.downloadDirectory) }
}
