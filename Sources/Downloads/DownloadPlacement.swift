import Foundation

/// Commits a completed staging file without deleting an existing destination before success.
enum DownloadPlacement {
    static func commit(staged: URL, to destination: URL, allowReplacement: Bool = false, files: FileManager = .default) throws {
        guard files.fileExists(atPath: staged.path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        }
        if !files.fileExists(atPath: destination.path) {
            try files.moveItem(at: staged, to: destination)
            return
        }
        guard allowReplacement else {
            throw NSError(
                domain: "Downloads", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "A file now exists at the chosen destination. Choose a different name to save this download."
                ])
        }
        let replacement = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: replacement) }
        let copy = replacement.appendingPathComponent(destination.lastPathComponent)
        try files.copyItem(at: staged, to: copy)
        _ = try files.replaceItemAt(destination, withItemAt: copy, backupItemName: nil, options: .usingNewMetadataOnly)
        try? files.removeItem(at: staged)
    }
}
