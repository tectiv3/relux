// swift-tools-version: 5.12
import PackageDescription

let package = Package(
    name: "Relux",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "ReluxCore"
        ),
        .executableTarget(
            name: "Relux",
            dependencies: [
                "ReluxCore",
                "KeyboardShortcuts",
            ]
        ),
        .executableTarget(
            name: "ReluxTool",
            dependencies: [
                "ReluxCore",
            ]
        ),
    ]
)
