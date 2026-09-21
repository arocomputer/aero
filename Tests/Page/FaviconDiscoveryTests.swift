import AppKit
import Testing
import WebKit
@testable import Browser

/// Streams the head in two pieces and leaves an image unfinished, without network or persistent storage.
@MainActor
private final class FaviconDocument: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    let page = URL(string: "https://favicon.example/page")!
    var document: (any WKURLSchemeTask)?
    var image: (any WKURLSchemeTask)?
    var committed = false
    var finished = false
    var result: NSImage?
    var discovery: Task<Void, Never>?
    let favicons: Favicons
    var current = true

    init(favicons: Favicons) { self.favicons = favicons }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
        if url.path == "/slow" {
            image = urlSchemeTask
        } else {
            document = urlSchemeTask
            urlSchemeTask.didReceive(Data(("<!doctype html><head>" + String(repeating: " ", count: 8192)).utf8))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        discovery = Task {
            committed = true
            result = await favicons.load(in: webView, page: page, isCurrent: { self.current })
            finished = true
        }
    }

    func finishDocument() {
        document?.didReceive(Data("<link rel='icon' href='https://favicon.example/declared.png'></head><body><img src='/slow'>".utf8))
        document?.didFinish()
        document = nil
    }
}

/// Gives WebKit callbacks time to arrive without opening a window or sending desktop input.
@MainActor
private func waitForFavicon(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// An evaluation queued after discovery confirms it is waiting in a still-parsing document.
@MainActor
private func documentState(_ view: WKWebView) async -> String? {
    await withCheckedContinuation { continuation in
        view.callAsyncJavaScript("return document.readyState", arguments: [:], in: nil, in: .defaultClient) { result in
            continuation.resume(returning: (try? result.get()) as? String)
        }
    }
}

@MainActor @Test func faviconDiscoveryPrecedesSlowResourcesAndHandlesAnAlreadyReadyDOM() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var requests: [URL] = []
    let favicons = Favicons(directory: directory) { url in
        requests.append(url)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return bitmap.representation(using: .png, properties: [:])
    }
    let fixture = FaviconDocument(favicons: favicons)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(fixture, forURLScheme: "fixture")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = fixture
    defer { view.stopLoading() }
    view.load(URLRequest(url: URL(string: "fixture://favicon/page")!))
    try #require(await waitForFavicon { fixture.committed })
    #expect(await documentState(view) == "loading")
    #expect(requests.isEmpty)
    fixture.finishDocument()
    try #require(await waitForFavicon { fixture.finished && fixture.image != nil })
    #expect(fixture.result != nil)
    #expect(requests.map(\.path) == ["/declared.png"])
    #expect(view.isLoading)

    let cached = await favicons.load(in: view, page: fixture.page, isCurrent: { true })
    #expect(cached === fixture.result)
    #expect(requests.count == 1)
}

@MainActor @Test func pendingDOMDiscoveryCannotFetchAfterClearOrSupersededNavigation() async throws {
    _ = NSApplication.shared
    for clear in [true, false] {
        var requests = 0
        let favicons = Favicons(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { _ in
            requests += 1
            return nil
        }
        let fixture = FaviconDocument(favicons: favicons)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(fixture, forURLScheme: "fixture")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = fixture
        defer { view.stopLoading() }
        view.load(URLRequest(url: URL(string: "fixture://favicon/page")!))
        try #require(await waitForFavicon { fixture.committed })
        #expect(await documentState(view) == "loading")
        if clear { favicons.clear() } else { fixture.current = false }
        fixture.finishDocument()
        #expect(await waitForFavicon { fixture.finished })
        #expect(fixture.result == nil)
        #expect(requests == 0)
    }
}
