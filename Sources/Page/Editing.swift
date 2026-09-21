import WebKit

/// Tracks edits in every frame so an embedded form cannot be discarded by tab sleeping.
/// Only a boolean crosses the isolated-world bridge, once per edited frame; field contents never do.
@MainActor final class Editing: NSObject, WKScriptMessageHandler {
    static let shared = Editing()
    private let tabs = NSMapTable<WKWebView, Tab>.weakToWeakObjects()
    private static let script = """
        (() => {
            let sent = false;
            addEventListener('input', event => {
                if (sent || !event.target?.closest?.('input, textarea, select, [contenteditable]')) return;
                sent = true;
                window.webkit.messageHandlers.browserEditing.postMessage(true);
            }, { capture: true, passive: true });
        })();
        """

    static func install(in controller: WKUserContentController) {
        controller.add(shared, contentWorld: .defaultClient, name: "browserEditing")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
    }

    func bind(_ view: WKWebView, to tab: Tab) { tabs.setObject(tab, forKey: view) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.body as? Bool == true, let view = message.webView, let tab = tabs.object(forKey: view), tab.webView === view else {
            return
        }
        tab.markEdited()
    }
}
