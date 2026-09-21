import AppKit
import Testing
import WebKit
@testable import Browser

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27))
func gpcReachesDocumentsFramesFetchesAndRedirects() async throws {
    _ = NSApplication.shared
    let server = try LocalHTTPServer(
        script: #"""
            from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
            import json
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args): pass
                def do_GET(self):
                    value = json.dumps(self.headers.get('Sec-GPC'))
                    if self.path == '/redirect':
                        self.send_response(302)
                        self.send_header('Location', 'http://127.0.0.1:%d/check' % self.server.server_port)
                        self.end_headers()
                        return
                    if self.path == '/check':
                        body = value
                    elif self.path == '/frame':
                        body = '<script>parent.postMessage({frame:true, header:%s, api:navigator.globalPrivacyControl}, "*")</script>' % value
                    else:
                        body = '''<script>
                            globalThis.results = {documentHeader: %s === '1', mainAPI: navigator.globalPrivacyControl === true};
                            addEventListener('message', event => {
                                if (event.data.frame) { results.frameHeader = event.data.header === '1'; results.frameAPI = event.data.api === true; }
                            });
                            fetch('http://127.0.0.1:%d/check').then(r => r.json()).then(v => results.fetchHeader = v === '1');
                            fetch('/redirect').then(r => r.json()).then(v => results.redirectHeader = v === '1');
                            </script><iframe src="http://127.0.0.1:%d/frame"></iframe>''' % (value, self.server.server_port, self.server.server_port)
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json' if self.path == '/check' else 'text/html')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    self.wfile.write(body.encode())
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            print(server.server_port, flush=True)
            server.serve_forever()
            """#)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    GlobalPrivacyControl.apply(to: configuration.defaultWebpagePreferences, enabled: true)
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    let host = PrivacyFixtureHost(view)
    view.navigationDelegate = host
    view.load(URLRequest(url: URL(string: "http://localhost:\(server.port)/")!))
    let deadline = ContinuousClock.now + .seconds(10)
    var result: [String: Bool] = [:]
    while ContinuousClock.now < deadline {
        result = (try? await view.evaluateJavaScript("globalThis.results || {}")) as? [String: Bool] ?? [:]
        if result.count == 6 { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(result.count == 6)
    for (name, value) in result { #expect(value, "GPC check: \(name)") }
    withExtendedLifetime(host) {}
}

/// Supplies the same per-navigation GPC policy used by browser tabs.
@MainActor private final class PrivacyFixtureHost: NSObject, WKNavigationDelegate {
    let view: WKWebView
    init(_ view: WKWebView) { self.view = view }
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        GlobalPrivacyControl.apply(to: preferences, enabled: true)
        decisionHandler(.allow, preferences)
    }
}
