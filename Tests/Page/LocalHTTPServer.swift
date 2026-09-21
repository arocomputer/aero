import Foundation

/// A disposable loopback fixture server. It reports only its assigned port, never request metadata.
final class LocalHTTPServer {
    let process = Process()
    let port: Int

    init(script: String) throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", script]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        var bytes = Data()
        while bytes.count < 8, let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }
            bytes.append(byte)
        }
        guard let port = Int(String(decoding: bytes, as: UTF8.self)), (1...65535).contains(port) else {
            if process.isRunning { process.terminate() }
            throw NSError(domain: "LocalHTTPFixture", code: 1)
        }
        self.port = port
    }

    deinit { if process.isRunning { process.terminate() }; process.waitUntilExit() }
}
