import AppKit
import Testing
import WebKit
@testable import Browser

@MainActor @Test func privateDownloadsKeepTheFileButNotPersistentHistory() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("private-download-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try LocalHTTPServer(
        script: #"""
            from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args): pass
                def do_GET(self):
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Disposition', 'attachment; filename="private-fixture.txt"')
                    self.send_header('Content-Length', '7')
                    self.end_headers()
                    self.wfile.write(b'fixture')
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            print(server.server_port, flush=True)
            server.serve_forever()
            """#)
    let file = root.appendingPathComponent("history.json")
    let downloads = Downloads(file: file, destinationDirectory: root)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    await withCheckedContinuation { continuation in
        view.startDownload(using: URLRequest(url: URL(string: "http://localhost:\(server.port)/fixture")!)) {
            downloads.accept($0, recordsActivity: false)
            continuation.resume()
        }
    }
    let item = try #require(downloads.items.first)
    defer { item.cancel(); item.discardStaging() }
    let deadline = ContinuousClock.now + .seconds(5)
    while item.state == .running && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    try #require(item.state == .finished)
    #expect(try String(contentsOf: #require(item.destination), encoding: .utf8) == "fixture")
    downloads.save()
    #expect(Downloads(file: file).items.isEmpty)
}
