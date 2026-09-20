import AppKit

/// The window's content view: the strip fills the system titlebar area, content and address field fill the rest.
final class RootView: NSView {
    private let strip: Strip, content: NSView, omnibox: NSView, linkBubble: NSView
    private let menuPanel: MenuPanel, find: FindBar
    /// Kept from the last windowed layout, because in full screen the titlebar leaves the window.
    private var stripHeight: CGFloat = 52
    /// The traffic lights' frames as the system lays them out, captured before they are first enlarged.
    private var systemLights: [NSRect] = []

    init(strip: Strip, content: NSView, linkBubble: NSView, omnibox: NSView, menuPanel: MenuPanel, find: FindBar) {
        (self.strip, self.content, self.omnibox, self.menuPanel, self.find) = (strip, content, omnibox, menuPanel, find)
        self.linkBubble = linkBubble
        super.init(frame: .zero)
        // The bubble lies over the page and under the address field, which covers the page when it shows.
        [content, linkBubble, omnibox, strip, menuPanel, find].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Lifts AppKit's native traffic lights 6pt with the strip and spreads their centers to 25pt while
    /// keeping the close button's horizontal position.
    private func placeTrafficLights(of window: NSWindow) {
        let spacing: CGFloat = 25
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        guard buttons.count == 3, let titlebar = buttons[0].superview, !window.styleMask.contains(.fullScreen) else { return }
        if systemLights.isEmpty {
            systemLights = buttons.map(\.frame)
        }

        let closeCenterX = systemLights[0].midX
        for (index, pair) in zip(buttons, systemLights).enumerated() {
            let (button, system) = pair
            let size = system.size
            let centeredY = (titlebar.bounds.height - size.height) / 2
            let frame = NSRect(
                x: closeCenterX + CGFloat(index) * spacing - size.width / 2,
                y: centeredY + (titlebar.isFlipped ? -6 : 6),
                width: size.width,
                height: size.height)
            if button.frame != frame {
                button.frame = frame
                button.setBoundsSize(system.size)
            }
        }
    }

    override func layout() {
        super.layout()
        if let window {
            let titlebarHeight = window.frame.height - window.contentLayoutRect.maxY
            if titlebarHeight > 0 { stripHeight = titlebarHeight }
            placeTrafficLights(of: window)
            // Tabs start right of the traffic lights, or at the edge when full screen hides them.
            let lights = window.standardWindowButton(.zoomButton)
            let lightsEnd = lights.map { $0.convert($0.bounds, to: nil).maxX } ?? 0
            strip.leadingInset = window.styleMask.contains(.fullScreen) ? 12 : lightsEnd + 18
        }
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        content.frame = NSRect(x: 0, y: stripHeight, width: bounds.width, height: bounds.height - stripHeight)
        omnibox.frame = content.frame
        linkBubble.frame = content.frame
        menuPanel.frame = bounds
        find.frame = bounds
        if let window, let close = window.standardWindowButton(.closeButton), !window.styleMask.contains(.fullScreen) {
            let trailingInset = close.convert(close.bounds, to: self).minX
            strip.trailingInset = trailingInset
            menuPanel.trailingInset = trailingInset
            find.trailingInset = trailingInset
        }
    }
}
