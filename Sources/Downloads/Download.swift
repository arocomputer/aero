import AppKit
import WebKit

/// Chooses a safe unused destination without overwriting an existing download.
enum DownloadDestination {
    static func availableURL(in directory: URL, suggestedFilename: String, fileExists: (String) -> Bool) -> URL {
        var filename = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        if filename.isEmpty || filename == "." || filename == ".." { filename = "Download" }
        let value = filename as NSString
        let ext = value.pathExtension
        let stem = value.deletingPathExtension
        var candidate = filename
        var copy = 2
        while fileExists(candidate) {
            candidate = ext.isEmpty ? "\(stem) \(copy)" : "\(stem) \(copy).\(ext)"
            copy += 1
        }
        return directory.appendingPathComponent(candidate)
    }
}

/// One transfer and its durable metadata. Private transfers never enter the persisted download list.
@MainActor final class DownloadItem: NSObject, WKDownloadDelegate {
    enum State: String, Codable { case running, paused, finished, failed, cancelled }
    struct Record: Codable {
        var id: UUID
        var filename: String
        var source: URL?
        var destination: URL?
        var bookmark: Data?
        var resumeData: Data?
        var state: State
        var created: Date
        var failure: String?
        var completedTransfer: Bool?
        var allowReplacement: Bool?
    }
    private(set) var record: Record
    let recordsActivity: Bool
    private let destinationDirectory: URL?
    private var transfer: WKDownload?
    private var progressObservation: NSKeyValueObservation?
    private var scopedDestination: URL?
    private var pausing = false
    private var cancelling = false
    private var pauseCompletions: [() -> Void] = []
    var onChange: (() -> Void)?

    init(download: WKDownload, recordsActivity: Bool, destinationDirectory: URL? = nil) {
        self.recordsActivity = recordsActivity
        self.destinationDirectory = destinationDirectory
        let source = download.originalRequest?.url
        record = Record(
            id: UUID(), filename: "Download", source: AddressInput.isWeb(source) ? source : nil, state: .running, created: Date())
        super.init()
        bind(download)
    }

    init(record: Record) {
        self.record = record
        recordsActivity = true
        destinationDirectory = nil
        super.init()
        if self.record.state == .running {
            self.record.state = record.resumeData == nil ? .failed : .paused
            self.record.failure = "The previous transfer was interrupted."
        }
    }

    var id: UUID { record.id }
    var filename: String { record.filename }
    var destination: URL? { record.destination }
    var state: State { record.state }
    var progress: Double {
        if state == .finished { return 1 }
        let value = transfer?.progress.fractionCompleted ?? 0
        return value.isFinite ? min(1, max(0, value)) : 0
    }
    var canResume: Bool { record.resumeData != nil }
    private var staging: URL {
        let root =
            recordsActivity
            ? AppPaths.support.appendingPathComponent("DownloadStaging")
            : FileManager.default.temporaryDirectory.appendingPathComponent("PrivateDownloads")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(id.uuidString)
    }

    private func bind(_ download: WKDownload) {
        transfer = download
        download.delegate = self
        record.state = .running
        record.failure = nil
        progressObservation = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onChange?() }
        }
        onChange?()
    }

    func cancel() {
        guard state != .finished else { return }
        cancelling = true
        if pausing { return }
        guard let transfer else { discardStaging(); record.state = .cancelled; onChange?(); return }
        pausing = true
        transfer.cancel { [self] _ in
            record.state = .cancelled
            record.resumeData = nil
            try? FileManager.default.removeItem(at: staging)
            releaseTransfer()
            onChange?()
        }
    }

    func pause(completion: @escaping () -> Void = {}) {
        if pausing { pauseCompletions.append(completion); return }
        guard state == .running, let transfer else { return completion() }
        pausing = true
        transfer.cancel { [self] data in
            if cancelling {
                discardStaging()
                record.state = .cancelled
            } else {
                record.resumeData = data
                record.state = data == nil ? .failed : .paused
                if data == nil { record.failure = "This transfer cannot resume. Retry to download it again." }
            }
            releaseTransfer()
            onChange?()
            completion()
        }
    }

    /// Restarts through WebKit so authentication and certificate handling use the browser's store.
    func restart(in webView: WKWebView) {
        guard state != .running else { return }
        pausing = false
        cancelling = false
        resolveDestination()
        if record.completedTransfer == true, FileManager.default.fileExists(atPath: staging.path) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                self.record.destination = url
                self.record.filename = url.lastPathComponent
                self.record.allowReplacement = FileManager.default.fileExists(atPath: url.path)
                if url.startAccessingSecurityScopedResource() { self.scopedDestination = url }
                self.finishPlacement()
            }
            return
        }
        if let data = record.resumeData {
            record.state = .running
            webView.resumeDownload(fromResumeData: data) { [weak self] in self?.bind($0) }
        } else if let source = record.source {
            try? FileManager.default.removeItem(at: staging)
            record.state = .running
            webView.startDownload(using: URLRequest(url: source)) { [weak self] in self?.bind($0) }
        }
        onChange?()
    }

    func reveal() {
        resolveDestination()
        if let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        scopedDestination?.stopAccessingSecurityScopedResource()
        scopedDestination = nil
    }

    private func resolveDestination() {
        guard scopedDestination == nil, let bookmark = record.bookmark else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
            if url.startAccessingSecurityScopedResource() { scopedDestination = url }
            record.destination = url
            record.allowReplacement =
                self.destinationDirectory == nil && Settings.asksDownloadDestination && FileManager.default.fileExists(atPath: url.path)
            if stale { record.bookmark = try? url.bookmarkData(options: .withSecurityScope) }
        }
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard download === transfer else { return completionHandler(nil) }
        if let response = response as? HTTPURLResponse, response.statusCode >= 400 {
            record.state = .failed
            record.failure = "The server returned HTTP \(response.statusCode)."
            onChange?()
            return completionHandler(nil)
        }
        if record.destination != nil { return completionHandler(staging) }
        let directory = destinationDirectory ?? Settings.downloadDirectory
        let target = DownloadDestination.availableURL(in: directory, suggestedFilename: suggestedFilename) {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        let choose: (URL?) -> Void = { [weak self] url in
            guard let self else { return completionHandler(nil) }
            guard let url else { record.state = .cancelled; onChange?(); return completionHandler(nil) }
            record.filename = url.lastPathComponent
            record.destination = url
            if url.startAccessingSecurityScopedResource() { scopedDestination = url }
            if FileManager.default.fileExists(atPath: url.path) { record.bookmark = try? url.bookmarkData(options: .withSecurityScope) }
            onChange?()
            completionHandler(staging)
        }
        if destinationDirectory == nil && Settings.asksDownloadDestination {
            let panel = NSSavePanel()
            panel.title = "Save Download"
            panel.directoryURL = directory
            panel.nameFieldStringValue = target.lastPathComponent
            panel.begin { choose($0 == .OK ? panel.url : nil) }
        } else {
            choose(target)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === transfer else { return }
        record.completedTransfer = true
        record.resumeData = nil
        finishPlacement()
    }

    private func finishPlacement() {
        do {
            guard let destination else {
                throw NSError(domain: "Downloads", code: 1, userInfo: [NSLocalizedDescriptionKey: "No download destination is available."])
            }
            try DownloadPlacement.commit(staged: staging, to: destination, allowReplacement: record.allowReplacement == true)
            record.bookmark = try? destination.bookmarkData(options: .withSecurityScope)
            record.state = .finished
            record.resumeData = nil
        } catch { record.state = .failed; record.failure = error.localizedDescription }
        releaseTransfer()
        onChange?()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard download === transfer, !pausing else { return }
        if record.state == .failed, record.failure != nil { releaseTransfer(); onChange?(); return }
        record.resumeData = resumeData
        record.state = (error as NSError).code == NSURLErrorCancelled ? .cancelled : .failed
        record.failure = error.localizedDescription
        releaseTransfer()
        onChange?()
    }

    private func releaseTransfer() {
        pausing = false
        progressObservation = nil
        transfer = nil
        scopedDestination?.stopAccessingSecurityScopedResource()
        scopedDestination = nil
        let completions = pauseCompletions
        pauseCompletions.removeAll()
        completions.forEach { $0() }
    }

    func discardStaging() {
        record.resumeData = nil
        try? FileManager.default.removeItem(at: staging)
    }

    func download(
        _ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }
}

/// One persistent normal-browsing download manager; private windows create an in-memory instance.
@MainActor final class Downloads {
    static let shared = Downloads(file: AppPaths.support.appendingPathComponent("downloads.json"))
    private(set) var items: [DownloadItem] = []
    var onChange: (() -> Void)?
    private let file: URL?
    private let destinationDirectory: URL?
    private var pendingSave: DispatchWorkItem?
    private var savedData: Data?

    init(file: URL? = nil, destinationDirectory: URL? = nil) {
        self.file = file
        self.destinationDirectory = destinationDirectory
        if let file, let data = try? Data(contentsOf: file), let records = try? JSONDecoder().decode([DownloadItem.Record].self, from: data)
        {
            savedData = data
            items = records.map(DownloadItem.init(record:))
            items.forEach(connect)
        }
    }

    func accept(_ download: WKDownload, recordsActivity: Bool = true) {
        let item = DownloadItem(download: download, recordsActivity: recordsActivity, destinationDirectory: destinationDirectory)
        connect(item)
        items.insert(item, at: 0)
        changed()
    }

    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.state != .running else { return }
        item.discardStaging()
        items.removeAll { $0.id == id }
        changed()
    }

    func pauseAll(completion: @escaping () -> Void) {
        let active = items.filter { $0.state == .running }
        guard !active.isEmpty else { save(); return completion() }
        var remaining = active.count
        for item in active {
            item.pause {
                remaining -= 1; if remaining == 0 { self.save(); completion() }
            }
        }
    }

    /// Closing a private window ends its transfers and removes partial files and in-memory records.
    func endPrivateSession(completion: @escaping () -> Void = {}) {
        pauseAll {
            self.items.forEach { $0.discardStaging() }
            self.items.removeAll()
            completion()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let file, let data = try? encoder.encode(items.filter(\.recordsActivity).map(\.record)), data != savedData else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: file, options: .atomic); savedData = data } catch { return }
    }

    private func connect(_ item: DownloadItem) { item.onChange = { [weak self] in self?.changed() } }
    private func changed() {
        onChange?()
        for window in NSApp?.windows ?? [] {
            if let controller = window.windowController as? WindowController, controller.downloads === self {
                controller.downloadsDidChange()
            }
        }
        guard file != nil, pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil; self?.save()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
