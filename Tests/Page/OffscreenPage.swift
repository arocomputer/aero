import ObjectiveC
import WebKit

/// A configuration for pages loaded in a window that is never shown, which is how the script is
/// tested without raising windows on anyone's desk. Such a page counts as hidden, and two things
/// follow from that which have nothing to do with what is being tested: the script lets a hidden
/// page wait, and WebKit slows a hidden page's timers, more the busier the machine, which made these
/// tests time out on a loaded CI runner. The script's own world is told the page is visible, and
/// WebKit is asked not to throttle; the page itself is left alone.
@MainActor func offscreenPageConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    // Private preferences, set by selector and only where they exist; the tests run without them.
    for name in ["_setHiddenPageDOMTimerThrottlingEnabled:", "_setPageVisibilityBasedProcessSuppressionEnabled:"] {
        let selector = NSSelectorFromString(name)
        guard configuration.preferences.responds(to: selector), let method = class_getInstanceMethod(WKPreferences.self, selector)
        else { continue }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(configuration.preferences, selector, false)
    }
    configuration.userContentController.addUserScript(
        WKUserScript(
            source: "Object.defineProperty(document, 'hidden', { get: () => false })",
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
    return configuration
}
