// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(
            name: "Browser",
            path: "Sources",
            resources: [.copy("Extensions/Extensions.html"), .copy("Settings/Settings.html")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "BrowserTests",
            dependencies: ["Browser"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
