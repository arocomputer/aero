import AppKit
import Foundation
import WebKit

/// Chooses a safe unused destination without overwriting an existing download.
enum DownloadDestination {
    static func availableURL(
        in directory: URL, suggestedFilename: String,
        fileExists: (String) -> Bool
    ) -> URL {
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

/// One WebKit download and the state shown in Aero's downloads menu.
final class DownloadItem: NSObject, WKDownloadDelegate {
    enum State {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let download: WKDownload
    private(set) var filename = "Download"
    private(set) var destination: URL?
    private(set) var state: State = .running
    var onChange: (() -> Void)?

    private var progressObservation: NSKeyValueObservation?

    init(download: WKDownload) {
        self.download = download
        super.init()
        download.delegate = self
        progressObservation = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onChange?() }
        }
    }

    var progress: Double { download.progress.fractionCompleted }

    func cancel() {
        download.cancel { _ in }
        state = .cancelled
        onChange?()
    }

    func reveal() {
        if let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse,
        suggestedFilename: String, completionHandler: @escaping (URL?) -> Void
    ) {
        let directory = Settings.downloadDirectory
        let destination = DownloadDestination.availableURL(in: directory, suggestedFilename: suggestedFilename) {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        filename = destination.lastPathComponent
        self.destination = destination
        onChange?()
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        state = .finished
        onChange?()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let error = error as NSError
        state = error.code == NSURLErrorCancelled ? .cancelled : .failed(error.localizedDescription)
        onChange?()
    }

    func download(
        _ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }
}

/// Owns downloads after their originating tabs close and publishes display changes to the window.
final class Downloads {
    private(set) var items: [DownloadItem] = []
    var onChange: (() -> Void)?

    func accept(_ download: WKDownload) {
        let item = DownloadItem(download: download)
        item.onChange = { [weak self] in self?.onChange?() }
        items.insert(item, at: 0)
        onChange?()
    }
}
