import Foundation

/// Directories for Aero-owned data. Callers keep each feature's filenames and storage rules local.
enum AppPaths {
    /// Copies data from the earlier bundle identity once, before WebKit or app storage is opened.
    static func migratePreviousIdentity() {
        guard let current = Bundle.main.bundleIdentifier else { return }
        let previous = ["com", "fschrhunt", ["a", "r", "o"].joined()].joined(separator: ".")
        guard current != previous else { return }

        let files = FileManager.default
        let library = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let roots = [
            files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            library.appendingPathComponent("WebKit", isDirectory: true),
            library.appendingPathComponent("HTTPStorages", isDirectory: true),
        ]
        for root in roots {
            let source = root.appendingPathComponent(previous, isDirectory: true)
            let destination = root.appendingPathComponent(current, isDirectory: true)
            guard files.fileExists(atPath: source.path), !files.fileExists(atPath: destination.path) else { continue }
            try? files.copyItem(at: source, to: destination)
        }

        guard let previousDefaults = UserDefaults(suiteName: previous) else { return }
        for key in ["pins", "extensions.v1"] where UserDefaults.standard.object(forKey: key) == nil {
            if let value = previousDefaults.object(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
        }
    }

    static let support: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "browser-dev", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
}
