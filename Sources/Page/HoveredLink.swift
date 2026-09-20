import WebKit

/// Receives the address of the link under the pointer from HoveredLink.js and passes it to the window
/// of the tab whose page sent it; an empty address means the pointer is over no link. One stateless
/// instance serves every web view, like `TintRouter`.
final class HoveredLink: NSObject, WKScriptMessageHandler {
    static let shared = HoveredLink()
    static let name = "link"

    /// The script, from HoveredLink.js beside this file, with the rules it follows.
    static let script: String = {
        let url = Bundle.module.url(forResource: "HoveredLink", withExtension: "js")!
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Adds the script, in every frame, and its message handler to a configuration's content controller.
    static func install(in controller: WKUserContentController, handler: WKScriptMessageHandler = shared) {
        controller.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        controller.add(handler, contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let address = message.body as? String, let tab = message.webView?.navigationDelegate as? Tab else { return }
        tab.owner?.tab(tab, isOverLink: address.isEmpty ? nil : address)
    }
}
