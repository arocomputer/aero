// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS("15.4")],
    targets: [
        // The icon is packaged separately from the executable.
        .executableTarget(
            name: "Browser",
            path: "Sources",
            exclude: ["UI/aero.icon"],
            resources: [.copy("Extensions/Extensions.html"), .copy("UI/Settings.html")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "BrowserTests",
            dependencies: ["Browser"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
