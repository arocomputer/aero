import AppKit
import CryptoKit
import Testing
import WebKit
@testable import Browser

@MainActor @Test func downloadsPauseResumeAndPersistCompletedRecords() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try LocalHTTPServer(
        script: #"""
            from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
            import time
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args): pass
                def do_GET(self):
                    size = 2 * 1024 * 1024
                    offset = int(self.headers.get('Range', 'bytes=0-').split('=')[1].split('-')[0])
                    self.send_response(206 if offset else 200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Disposition', 'attachment; filename="transfer.bin"')
                    self.send_header('Content-Length', str(size - offset))
                    self.send_header('Accept-Ranges', 'bytes')
                    self.send_header('ETag', '"fixture-v1"')
                    self.send_header('Last-Modified', 'Sun, 20 Sep 2026 00:00:00 GMT')
                    if offset: self.send_header('Content-Range', 'bytes %d-%d/%d' % (offset, size - 1, size))
                    self.end_headers()
                    try:
                        while offset < size:
                            count = min(4096, size - offset)
                            self.wfile.write(b'A' * count)
                            self.wfile.flush()
                            offset += count
                            time.sleep(.005)
                    except (BrokenPipeError, ConnectionResetError): pass
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            print(server.server_port, flush=True)
            server.serve_forever()
            """#)
    let manager = Downloads(file: root.appendingPathComponent("history.json"), destinationDirectory: root)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    await withCheckedContinuation { continuation in
        view.startDownload(using: URLRequest(url: URL(string: "http://localhost:\(server.port)/download")!)) { download in
            manager.accept(download)
            continuation.resume()
        }
    }
    let item = try #require(manager.items.first)
    defer { item.cancel(); item.discardStaging() }
    let progressDeadline = ContinuousClock.now + .seconds(5)
    while item.progress == 0 && item.state == .running && ContinuousClock.now < progressDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(item.state == .running)
    await withCheckedContinuation { continuation in item.pause { continuation.resume() } }
    #expect(item.state == .paused)
    try #require(item.canResume)
    item.restart(in: view)
    let finishDeadline = ContinuousClock.now + .seconds(15)
    while item.state == .running && ContinuousClock.now < finishDeadline { try await Task.sleep(for: .milliseconds(50)) }
    try #require(item.state == .finished, "Transfer result: \(item.record.failure ?? item.state.rawValue)")
    let destination = try #require(item.destination)
    let data = try Data(contentsOf: destination)
    #expect(data.count == 2 * 1024 * 1024)
    #expect(SHA256.hash(data: data) == SHA256.hash(data: Data(repeating: 65, count: 2 * 1024 * 1024)))
    manager.save()
    let restored = Downloads(file: root.appendingPathComponent("history.json"))
    #expect(restored.items.first?.state == .finished)
    #expect(restored.items.first?.destination == destination)
}
