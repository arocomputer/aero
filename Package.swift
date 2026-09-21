// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS("15.4")],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "Browser",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources",
            // SwiftPM treats anything it does not recognize inside a target as an undeclared
            // resource. A folder's README is documentation; list it here when one is added.
            exclude: ["Page/README.md"],
            resources: [
                .copy("Extensions/Extensions.html"), .copy("Settings/Settings.html"), .copy("Page/PageTint.js"),
                .copy("Page/HoveredLink.js"),
                .copy("Page/Trackers.txt"), .copy("Page/TrackerListNotice.txt"),
                .copy("Settings/BrowserPage.css"), .copy("Settings/BrowserPage.js"),
                .copy("Settings/Settings.js"), .copy("Extensions/Extensions.js"),
                .copy("Settings/Library.html"), .copy("Settings/Library.js"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(
            name: "BrowserTests",
            dependencies: ["Browser"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
