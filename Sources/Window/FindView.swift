import AppKit
import WebKit

/// A compact find bar that searches the current web view without injecting code into the page.
final class FindView: NSView, NSSearchFieldDelegate {
    var trailingInset: CGFloat = 14 { didSet { if trailingInset != oldValue { needsLayout = true } } }
    private let card = CardView()
    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let previous = StripButton(symbol: "chevron.up", pointSize: 11)
    private let next = StripButton(symbol: "chevron.down", pointSize: 11)
    private let done = StripButton(symbol: "xmark", pointSize: 11)
    private weak var webView: WKWebView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        field.placeholderString = "Find on page"
        field.focusRingType = .none
        field.delegate = self
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        previous.toolTip = "Previous Match"
        next.toolTip = "Next Match"
        done.toolTip = "Done"
        previous.onClick = { [weak self] in self?.search(backwards: true) }
        next.onClick = { [weak self] in self?.search(backwards: false) }
        done.onClick = { [weak self] in self?.dismiss() }
        [field, status, previous, next, done].forEach(card.addSubview)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func present(for webView: WKWebView) {
        self.webView = webView
        isHidden = false
        alphaValue = 1
        status.stringValue = ""
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        guard !isHidden else { return }
        webView?.find("") { _ in }
        webView = nil
        field.stringValue = ""
        status.stringValue = ""
        isHidden = true
    }

    override func layout() {
        super.layout()
        let width: CGFloat = 360
        card.frame = NSRect(x: bounds.width - width - trailingInset, y: 58, width: width, height: 44)
        field.frame = NSRect(x: 10, y: 8, width: 205, height: 28)
        status.frame = NSRect(x: 218, y: 14, width: 54, height: 16)
        previous.frame = NSRect(x: 274, y: 8, width: 28, height: 28)
        next.frame = NSRect(x: 302, y: 8, width: 28, height: 28)
        done.frame = NSRect(x: 330, y: 8, width: 28, height: 28)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        card.frame.contains(point) ? super.hitTest(point) : nil
    }

    func controlTextDidChange(_ notification: Notification) { search(backwards: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)): search(backwards: false)
        case #selector(cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    private func search(backwards: Bool) {
        guard let webView, !field.stringValue.isEmpty else {
            status.stringValue = ""
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(field.stringValue, configuration: configuration) { [weak self] result in
            self?.status.stringValue = result.matchFound ? "" : "No match"
        }
    }
}
