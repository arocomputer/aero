import AppKit
import Testing
@testable import Browser

/// A 200×2 image filled with `background`, with a `logo`-colored block covering a fifth of its width.
private func edge(background: NSColor, logo: NSColor) -> CGImage {
    let context = CGContext(
        data: nil, width: 200, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 2))
    context.setFillColor(logo.cgColor)
    context.fill(CGRect(x: 20, y: 0, width: 40, height: 2))
    return context.makeImage()!
}

@Test func dominantColorIgnoresMinorityContentOnTheEdge() throws {
    let navy = NSColor(srgbRed: 0, green: 0.01, blue: 0.25, alpha: 1)
    let color = try #require(DominantColor.of(edge(background: navy, logo: .white)))
    #expect(abs(color.redComponent - 0) < 0.02)
    #expect(abs(color.blueComponent - 0.25) < 0.02)
}
