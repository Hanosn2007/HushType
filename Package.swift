// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HushType",
    // Resources/HushType contains en, zh-Hans, and zh-Hant-TW interface
    // catalogs; Makefile and scripts/check_localizations.sh copy and validate
    // this same locale set for packaged builds.
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/felixfu824/speech-swift.git", revision: "d603472b11c21f5fb6492e9448a04ee669d0bf64"),
        // Direct mlx-swift dep so live caption can bound the GPU buffer cache
        // (MLX.GPU.set(cacheLimit:) / clearCache) — speech-swift transitively
        // depends on the same version, so SwiftPM resolves a single copy.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
    ],
    targets: [
        .target(
            name: "ExceptionCatcher",
            path: "Sources/ExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "HushType",
            dependencies: [
                "ExceptionCatcher",
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/HushType",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "HushTypeTests",
            dependencies: ["HushType", "ExceptionCatcher"],
            path: "Tests/HushTypeTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
