// swift-tools-version: 5.12
import PackageDescription

let package = Package(
    name: "Relux",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Relux",
            dependencies: [
                "KeyboardShortcuts",
            ]
        ),
    ]
)
