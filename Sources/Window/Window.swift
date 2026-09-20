import AppKit

/// Aero's native window. It owns shortcuts that should work without appearing as menu items and
/// remembers where a double-click began before its first click can rearrange the tab strip.
final class Window: NSWindow {
    private(set) var firstClickAllowsZoom = false

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 1 {
            firstClickAllowsZoom =
                (windowController as? WindowController)?.allowsWindowZoom(at: event.locationInWindow) ?? false
        }
        super.sendEvent(event)
    }

    override func performZoom(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.clickCount >= 2 {
            guard firstClickAllowsZoom,
                (windowController as? WindowController)?.allowsWindowZoom(at: event.locationInWindow) == true
            else { return }
        }
        super.performZoom(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
            let character = event.charactersIgnoringModifiers,
            let number = Int(character),
            (1...9).contains(number),
            let controller = windowController as? WindowController
        {
            return controller.selectTab(number: number)
        }
        if modifiers == [.command, .shift],
            let character = event.charactersIgnoringModifiers,
            let controller = windowController as? WindowController
        {
            if character == "[" { controller.selectPreviousTab(nil); return true }
            if character == "]" { controller.selectNextTab(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
