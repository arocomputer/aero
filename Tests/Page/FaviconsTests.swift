import AppKit
import Foundation
import Testing
@testable import Browser

private let page = URL(string: "https://aero.example/docs/start")!

private func icon(_ path: String, size: Int? = nil, touch: Bool = false) -> DeclaredIcon {
    DeclaredIcon(url: URL(string: "https://aero.example/\(path)")!, size: size, isTouchIcon: touch)
}

/// A solid square PNG, standing in for a downloaded icon.
private func png(pixels: Int = 64) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return bitmap.representation(using: .png, properties: [:])!
}

/// A disc of one color on a clear ground, with an optional square of a second color inside it.
private func mark(_ color: NSColor, inner: NSColor? = nil) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 56, height: 56)).fill()
    inner?.setFill()
    NSRect(x: 22, y: 22, width: 20, height: 20).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("favicons-\(UUID().uuidString)", isDirectory: true)
}

@Test func smallestIconCoveringRetinaSizeIsTriedFirst() {
    let declared = [
        icon("touch.png", size: 180, touch: true), icon("16.png", size: 16), icon("any.svg"),
        icon("192.png", size: 192), icon("32.png", size: 32),
    ]
    let paths = Favicons.candidates(declared: declared, page: page).map(\.path)
    #expect(paths == ["/32.png", "/192.png", "/any.svg", "/16.png", "/touch.png", "/favicon.ico"])
}

@Test func onlyWebAddressesAreFetched() {
    let declared = [DeclaredIcon(url: URL(string: "data:image/png;base64,AAAA")!, size: 32, isTouchIcon: false)]
    #expect(Favicons.candidates(declared: declared, page: page).map(\.path) == ["/favicon.ico"])
}

@Test func thirdPartyIconsCannotBypassWebKitProtection() {
    let declared = [
        DeclaredIcon(url: URL(string: "https://tracker.example/icon.png")!, size: 32, isTouchIcon: false),
        DeclaredIcon(url: URL(string: "http://aero.example/icon.png")!, size: 32, isTouchIcon: false),
        icon("own.png", size: 32),
    ]
    #expect(
        Favicons.candidates(declared: declared, page: page).map(\.absoluteString) == [
            "https://aero.example/own.png", "https://aero.example/favicon.ico",
        ])
}

@Test func declaredSizesUseTheLargestWidthAndMarkTouchIcons() {
    let declared = Favicons.declared(from: [
        ["href": "https://aero.example/icon.ico", "sizes": "16x16 48X48", "rel": "shortcut icon"],
        ["href": "https://aero.example/touch.png", "sizes": "", "rel": "apple-touch-icon"],
        ["href": "", "sizes": "any", "rel": "icon"],
    ])
    #expect(declared == [icon("icon.ico", size: 48), icon("touch.png", touch: true)])
}

@MainActor @Test func loadedIconIsRememberedForItsHostAcrossLaunches() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let favicons = Favicons(directory: directory) { _ in png() }
    #expect(favicons.icon(for: page) == nil)

    let loaded = await favicons.load(declared: [], page: page)
    #expect(loaded?.size == NSSize(width: 16, height: 16))

    let relaunched = Favicons(directory: directory) { _ in nil }
    let remembered = relaunched.icon(for: URL(string: "https://aero.example/elsewhere"))
    #expect((remembered?.representations.first as? NSBitmapImageRep)?.pixelsWide == 32)
    #expect(relaunched.icon(for: URL(string: "https://other.example/")) == nil)
}

@Test func onlySingleToneIconsTakeTheSurfacesTextColor() throws {
    let isTemplate = { (data: Data) in Favicons.isSingleTone(try #require(Favicons.bitmap(from: data))) }
    #expect(try isTemplate(mark(.black)))
    #expect(try isTemplate(mark(.white)))
    #expect(try !isTemplate(mark(.systemRed)))
    #expect(try !isTemplate(mark(.black, inner: .white)))
}

@MainActor @Test func addressThatAnswersWithoutAnImageIsNotAskedAgain() async {
    var requests = 0
    let favicons = Favicons(directory: temporaryDirectory()) { _ in
        requests += 1
        return Data("not an image".utf8)
    }
    #expect(await favicons.load(declared: [], page: page) == nil)
    #expect(await favicons.load(declared: [], page: page) == nil)
    #expect(requests == 1)
}

@MainActor @Test func clearingForgetsIconsInMemoryAndOnDisk() async {
    let directory = temporaryDirectory()
    let favicons = Favicons(directory: directory) { _ in png() }
    _ = await favicons.load(declared: [], page: page)
    favicons.clear()
    #expect(favicons.icon(for: page) == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@MainActor @Test func pendingIconCannotRepopulateClearedHistory() async {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    weak var pending: Favicons?
    let favicons = Favicons(directory: directory) { _ in
        pending?.clear()
        return png()
    }
    pending = favicons
    #expect(await favicons.load(declared: [], page: page) == nil)
    #expect(favicons.icon(for: page) == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}
