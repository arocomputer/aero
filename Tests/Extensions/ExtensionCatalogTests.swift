import Foundation
import Testing
import WebKit

@testable import Browser

/// An extension names and describes itself, and Aero shows those words on a page that can install and
/// remove extensions. They are text, never markup, or an extension could write its own buttons there.
@MainActor @Test func anExtensionsOwnWordsCannotBecomeMarkupInTheCatalog() {
    let card = ExtensionCatalog.cardHTML(
        name: #"<img src=x onerror=alert(1)>"#, summary: #"Says "hello" & <b>waves</b>"#,
        category: "installed", icon: #"https://a.example/i.png" onload="x"#,
        action: #"<a class="button danger" href="aero://extensions/action/remove?id=1">Remove</a>"#)

    #expect(card.contains("&lt;img src=x onerror=alert(1)&gt;"))
    #expect(!card.contains("<img src=x"))
    #expect(!card.contains("<b>waves"))
    // Nothing an extension supplies may close an attribute and start another.
    #expect(!card.contains(#" onload="x"#))
    #expect(card.contains("&quot;hello&quot;"))
    // The action is the one argument that is markup, and every caller builds it from constants.
    #expect(card.contains(#"<a class="button danger""#))
}

/// Collects what a scheme handler answers a request with.
private final class StubTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var data = Data()
    private(set) var failure: (any Error)?
    private(set) var finished = false

    init(_ address: String) {
        request = URLRequest(url: URL(string: address)!)
    }

    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: any Error) { failure = error }
}

/// `aero:` pages are served from memory and carry the privileges of the app, so the handler answers
/// the two addresses it knows and nothing else. A page that talked its way into another address would
/// be a remote site holding those privileges.
@MainActor @Test func aeroPagesServeTheirOwnTwoAddressesAndNothingElse() {
    let webView = WKWebView()
    let settings = StubTask("aero://settings")
    AeroPages.shared.webView(webView, start: settings)
    #expect(settings.finished)
    #expect(String(data: settings.data, encoding: .utf8)?.contains("<html") == true)

    for address in ["aero://settings/anything", "aero://extensions/action/remove?id=1", "aero://elsewhere", "aero://"] {
        let task = StubTask(address)
        AeroPages.shared.webView(webView, start: task)
        #expect(task.failure != nil, "\(address) should not be served")
        #expect(task.data.isEmpty, "\(address) should not be served")
    }
}
