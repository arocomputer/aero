import AppKit
import Testing
import WebKit

@testable import Browser

/// Writes a picture of a real browser window — the strip, the page, and whether the one took its color
/// from the other — to a file, without ever putting a window on screen. That is the check the app's
/// own rules ask for on a visual change, and the one thing that cannot be done by running the app
/// without taking the screen from whoever is using it.
///
/// It lives in the test target on purpose: the shipping browser carries no screenshot mode, so there
/// is no flag that makes Aero render a page and write a file on someone else's say-so.
///
/// `./x shot [url] [file.png] [seconds]`, and it prints the file's path when it is written.
///
/// What it captures and what it cannot: the window's content — the strip and the page under it — at
/// 2x. The traffic lights belong to the system's titlebar, which is not part of the content view, so
/// they are not in the picture; everything Aero draws is. A layer is rendered where it has settled, so
/// a strip mid-fade shows the color it is fading to, not a frame of the fade.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["AERO_SHOT_URL"] != nil))
func windowShot() async throws {
    let environment = ProcessInfo.processInfo.environment
    let address = environment["AERO_SHOT_URL"] ?? "about:blank"
    let url = try #require(AddressInput.url(for: address), "AERO_SHOT_URL is not an address: \(address)")
    let output = URL(fileURLWithPath: environment["AERO_SHOT_OUTPUT"] ?? "build/shot.png")
    let settle = Double(environment["AERO_SHOT_SETTLE"] ?? "") ?? 4
    let size = shotSize(environment["AERO_SHOT_SIZE"])

    let controller = WindowController()
    let window = try #require(controller.window)
    window.setContentSize(size)
    let tab = try #require(controller.active)
    // The page is never on screen, so it counts as hidden: the script would hold its follow-up reads
    // and WebKit would stop the frames it watches for. Its own world is told otherwise; the page is
    // left alone. Tests/Page/OffscreenPage.swift does the same for the same reason.
    tab.webView.configuration.userContentController.addUserScript(
        WKUserScript(
            source: "Object.defineProperty(document, 'hidden', { get: () => false })",
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
    controller.navigate(to: url)

    let root = try #require(window.contentView)
    for _ in 0..<600 where tab.webView.isLoading {
        root.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
    }
    // Loaded is not settled: the strip's color arrives with the page's first reports, and a header
    // that fades in reports again after it has.
    try? await Task.sleep(for: .seconds(settle))
    root.layoutSubtreeIfNeeded()
    root.display()
    CATransaction.flush()

    let picture = try #require(await capture(window: window, page: tab.webView), "the window could not be pictured")
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #require(picture.representation(using: .png, properties: [:])).write(to: output)
    print("SHOT \(output.path) \(Int(size.width))x\(Int(size.height)) strip \(describe(tab.tint))")
}

/// "1280x820" from `AERO_SHOT_SIZE`, or the window size Aero opens with.
private func shotSize(_ text: String?) -> NSSize {
    let parts = (text ?? "").lowercased().split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2, parts[0] >= 480, parts[1] >= 320 else { return NSSize(width: 1280, height: 820) }
    return NSSize(width: parts[0], height: parts[1])
}

private func describe(_ color: NSColor?) -> String {
    guard let color = color.flatMap({ $0.usingColorSpace(.sRGB) }) else { return "none" }
    return [color.redComponent, color.greenComponent, color.blueComponent].map { String(Int(($0 * 255).rounded())) }
        .joined(separator: ",")
}

/// Draws the window's chrome and its page into one image. The chrome is a layer tree — the strip shows
/// its color by setting one, so drawing the views would miss it — and the page renders in its own
/// process, which no layer of ours holds, so WebKit is asked for it separately and it goes on top.
@MainActor private func capture(window: NSWindow, page: WKWebView) async -> NSBitmapImageRep? {
    guard let root = window.contentView else { return nil }
    root.wantsLayer = true
    let size = root.bounds.size
    let scale = 2
    guard size.width > 0, size.height > 0,
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = size

    let pageImage = try? await page.takeSnapshot(configuration: nil)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    // The window's layers are geometry-flipped, the way the views above them are, so the chrome is
    // drawn into a context turned the same way up. AppKit's own drawing below is not.
    context.cgContext.saveGState()
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    root.layer?.render(in: context.cgContext)
    context.cgContext.restoreGState()
    // The page's own frame, in the bottom-left coordinates AppKit draws in.
    let frame = page.convert(page.bounds, to: root)
    pageImage?.draw(in: NSRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height))
    return rep
}
