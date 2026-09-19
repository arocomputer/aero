// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Browser", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BrowserTests", dependencies: ["Browser"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
