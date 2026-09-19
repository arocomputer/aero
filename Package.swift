// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS(.v14)],
    targets: [
        // The icon is packaged by ./x app, not compiled into the executable.
        .executableTarget(name: "Browser", exclude: ["AppIcon.icon"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BrowserTests", dependencies: ["Browser"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
