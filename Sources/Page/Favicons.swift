import AppKit

/// One icon a page declares in its head, as reported by `Favicons.declaredScript`.
struct DeclaredIcon: Equatable {
    let url: URL
    /// The largest width in its `sizes` attribute, in pixels; nil when absent or "any".
    let size: Int?
    /// An apple-touch-icon: large and opaque, so it is tried only after real favicons.
    let isTouchIcon: Bool
}

/// Site icons for tabs and address suggestions. A tab hands over the icons its page declares; the best
/// one is fetched without cookies, redrawn at 32 pixels and remembered per host as a PNG, so
/// suggestions and restored pinned tabs have an icon before any page loads. An icon of a single dark
/// or light tone comes back as a template image, so it takes the text color of whatever surface it is
/// drawn on instead of vanishing into a strip of its own tone. Callers check
/// `Settings.showsFavicons` first: while it is off nothing here is asked for or fetched.
@MainActor
final class Favicons {
    static let shared = Favicons(directory: AppPaths.support.appendingPathComponent("Favicons", isDirectory: true))

    /// The body for `callAsyncJavaScript` that lists a page's declared icons, skipping ones whose
    /// media query, such as a color scheme, doesn't apply. It reads the head once and changes nothing.
    nonisolated static let declaredScript = """
        return [...document.querySelectorAll('link[rel~="icon" i], link[rel~="apple-touch-icon" i]')]
            .filter(link => link.href && (!link.media || matchMedia(link.media).matches))
            .map(link => ({ href: link.href, sizes: link.getAttribute('sizes') || '', rel: link.rel.toLowerCase() }))
        """

    private let directory: URL
    /// Icons by host. Both caches are bounded and give way under memory pressure; the disk has the rest.
    private let byHost = NSCache<NSString, NSImage>()
    /// This session's downloads by address. Pages on one host can declare different icons, so a tab
    /// asks again on every load and is answered from here.
    private let fetched = NSCache<NSURL, NSImage>()
    private var failed: Set<URL> = []
    private let fetch: (URL) async throws -> Data?
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// Keeps its PNGs in `directory`, created when the first icon is stored. `fetch` returns an
    /// address's data, nil when the server answers without any, and throws when it can't be reached.
    init(directory: URL, fetch: @escaping (URL) async throws -> Data? = Favicons.download) {
        self.directory = directory
        self.fetch = fetch
        byHost.countLimit = 300
        fetched.countLimit = 100
    }

    /// Downloads an icon without sending or keeping cookies. The page names the address, so the
    /// download is given up once it passes `limit` rather than held in memory whole.
    nonisolated static func download(_ url: URL) async throws -> Data? {
        let limit = 2_000_000
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= limit else { return nil }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { return nil }
        }
        return data
    }

    /// Turns the result of `declaredScript` into icons, dropping entries without a usable address.
    nonisolated static func declared(from result: Any?) -> [DeclaredIcon] {
        (result as? [[String: Any]] ?? []).compactMap { entry in
            guard let href = entry["href"] as? String, let url = URL(string: href) else { return nil }
            let widths = (entry["sizes"] as? String ?? "").lowercased().split(separator: " ")
                .compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
            let rel = entry["rel"] as? String ?? ""
            return DeclaredIcon(url: url, size: widths.max(), isTouchIcon: rel.contains("apple-touch-icon"))
        }
    }

    /// The addresses to try for a page's icon, best first. An icon is drawn at 16 points, 32 pixels on
    /// a Retina display, so the smallest declared icon of at least that size wins, then unsized ones
    /// (often an SVG or a multi-size .ico), then the largest of the small ones, then touch icons, and
    /// last the conventional /favicon.ico. Only http(s) addresses are kept.
    nonisolated static func candidates(declared: [DeclaredIcon], page: URL) -> [URL] {
        func rank(_ icon: DeclaredIcon) -> (Int, Int) {
            if icon.isTouchIcon { return (3, 0) }
            guard let size = icon.size else { return (1, 0) }
            return size >= 32 ? (0, size) : (2, -size)
        }
        let ordered = declared.enumerated().sorted { first, second in
            let (a, b) = (rank(first.element), rank(second.element))
            return a != b ? a < b : first.offset < second.offset
        }
        var urls = ordered.map(\.element.url)
        if let conventional = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL { urls.append(conventional) }
        var seen: Set<URL> = []
        return urls.filter { AddressInput.isWeb($0) && seen.insert($0).inserted }
    }

    /// The icon remembered for the address's host, from memory or disk; nil when there is none yet.
    func icon(for url: URL?) -> NSImage? {
        guard let host = url?.host?.lowercased() else { return nil }
        if let known = byHost.object(forKey: host as NSString) { return known }
        guard let image = (try? Data(contentsOf: file(for: host))).flatMap(NSBitmapImageRep.init(data:)).map(Self.image)
        else { return nil }
        byHost.setObject(image, forKey: host as NSString)
        return image
    }

    /// Fetches the best icon for `page` among the ones it declared and remembers it for the host.
    /// Returns nil when no candidate yields an image.
    func load(declared: [DeclaredIcon], page: URL) async -> NSImage? {
        guard let host = page.host?.lowercased() else { return nil }
        for url in Self.candidates(declared: declared, page: page) where !failed.contains(url) {
            if let image = fetched.object(forKey: url as NSURL) {
                remember(image, for: host)
                return image
            }
            // Trouble reaching the server may pass, so only an answer without an image rules an address out.
            let answer: Data?
            do { answer = try await fetch(url) } catch { continue }
            guard let bitmap = answer.flatMap(Self.bitmap) else {
                if failed.count >= 500 { failed.removeAll() }
                failed.insert(url)
                continue
            }
            let image = Self.image(bitmap)
            fetched.setObject(image, forKey: url as NSURL)
            remember(image, for: host)
            return image
        }
        return nil
    }

    /// Forgets every icon, in memory and on disk. Icons name the sites visited, so this goes with
    /// clearing history.
    func clear() {
        byHost.removeAllObjects()
        fetched.removeAllObjects()
        failed = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func remember(_ image: NSImage, for host: String) {
        if byHost.object(forKey: host as NSString) === image { return }
        byHost.setObject(image, forKey: host as NSString)
        guard let bitmap = image.representations.first as? NSBitmapImageRep,
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: file(for: host), options: .atomic)
    }

    private func file(for host: String) -> URL {
        let name = host.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-"))) ?? "_"
        return directory.appendingPathComponent(name + ".png")
    }

    /// Decodes image data of any kind the system reads and redraws it, fitted, into 32 by 32 pixels.
    nonisolated static func bitmap(from data: Data) -> NSBitmapImageRep? {
        guard let source = NSImage(data: data), source.isValid, source.size.width > 0, source.size.height > 0,
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // Sized before the context is made, so drawing in points lands on two pixels each.
        bitmap.size = NSSize(width: 16, height: 16)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let scale = min(16 / source.size.width, 16 / source.size.height)
        let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(x: (16 - size.width) / 2, y: (16 - size.height) / 2, width: size.width, height: size.height),
            from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// Wraps a 32-pixel bitmap as the 16-point image the strip and suggestions draw.
    private nonisolated static func image(_ bitmap: NSBitmapImageRep) -> NSImage {
        bitmap.size = NSSize(width: 16, height: 16)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        image.isTemplate = isSingleTone(bitmap)
        return image
    }

    /// Whether an icon is one dark or one light shape on a clear ground, like GitHub's mark. Sites
    /// seldom offer a second icon for dark surfaces, and the strip's tone follows the page rather than
    /// the system, so such an icon is drawn in the text color instead. Icons with color or with two
    /// tones read on any surface and are left as they are.
    nonisolated static func isSingleTone(_ bitmap: NSBitmapImageRep) -> Bool {
        var (total, dark, light) = (0.0, 0.0, 0.0)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.1 else { continue }
                let (red, green, blue) = (color.redComponent, color.greenComponent, color.blueComponent)
                total += color.alphaComponent
                guard max(red, green, blue) - min(red, green, blue) < 0.15 else { continue }
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                if luminance < 0.3 { dark += color.alphaComponent } else if luminance > 0.75 { light += color.alphaComponent }
            }
        }
        return total > 0 && max(dark, light) >= total * 0.97
    }
}
