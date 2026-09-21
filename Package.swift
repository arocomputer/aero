// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS("15.4")],
    targets: [
        .executableTarget(
            name: "Browser",
            path: "Sources",
            // SwiftPM treats anything it does not recognize inside a target as an undeclared
            // resource. A folder's README is documentation; list it here when one is added.
            exclude: ["Page/README.md"],
            resources: [
                .copy("Extensions/Extensions.html"), .copy("Settings/Settings.html"), .copy("Page/PageTint.js"),
                .copy("Page/HoveredLink.js"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "BrowserTests",
            dependencies: ["Browser"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
