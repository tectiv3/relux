// swift-tools-version: 5.12
import PackageDescription

let package = Package(
    name: "Relux",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.30.6")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "2.30.6")),
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
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
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
