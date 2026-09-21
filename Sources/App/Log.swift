import Foundation

/// A running commentary on the decisions that leave no trace on screen: which color a page asked the
/// strip to take and whether that cost a snapshot, why a tab did or did not sleep, how long a reload
/// stayed covered. Those are the parts that are hard to see by looking at the app, and hard to reach
/// from a test once a real page is involved.
///
/// Every channel is off unless `AERO_LOG` names it, so an ordinary run neither opens the file nor
/// builds the messages: `AERO_LOG=tint,sleep ./x dev`, or `AERO_LOG=all`. Lines go to `log.txt` beside
/// the app's other data, one file per run, and `./x log` follows it. A file rather than the unified
/// log because it is readable without privileges, and because a dev build writes it under its own
/// bundle identifier, where it cannot be confused with anything the real app keeps.
///
/// Nothing here may name a page. Addresses, titles and page content are private, so a tab is named by
/// what it reported and never by where it is. That is deliberate; do not "improve" it by adding the URL.
enum Log {
    enum Channel: String {
        case tint
        case reload
        case sleep
    }

    private static let named: Set<String> = Set(
        (ProcessInfo.processInfo.environment["AERO_LOG"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })

    /// Opened on the first line written, and truncated then, so each run starts its own log.
    private static let file: FileHandle? = {
        let url = AppPaths.support.appendingPathComponent("log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    private static let queue = DispatchQueue(label: "log")

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Whether `channel` is on. Worth asking before assembling anything expensive to say.
    static func on(_ channel: Channel) -> Bool {
        named.contains(channel.rawValue) || named.contains("all")
    }

    /// Records one line on `channel`. `message` is not built when the channel is off.
    static func write(_ channel: Channel, _ message: @autoclosure () -> String) {
        guard on(channel) else { return }
        let line = "\(clock.string(from: Date())) \(channel.rawValue)  \(message())\n"
        queue.async { file?.write(Data(line.utf8)) }
    }
}
