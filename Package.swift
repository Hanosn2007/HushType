// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path
let swiftUIShimSearchPath = "\(packageDirectory)/Sources/SwiftUIShim"

let package = Package(
    name: "HushType",
    // Resources/HushType contains en, zh-Hans, and zh-Hant-TW interface
    // catalogs; Makefile and scripts/check_localizations.sh copy and validate
    // this same locale set for packaged builds.
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
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
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/HushType",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                // Swift's module loader compiles this source interface into the
                // derived module cache. It preserves SwiftUI's system ABI and
                // avoids tracking an architecture-specific .swiftmodule.
                .unsafeFlags([
                    "-I\(swiftUIShimSearchPath)",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth"),
            ]
        ),
        .testTarget(
            name: "HushTypeTests",
            dependencies: ["HushType", "ExceptionCatcher"],
            path: "Tests/HushTypeTests",
            // HushType's module interface records its ordinary SwiftUI_SPI
            // import, so test compilation needs the same source-interface path.
            swiftSettings: [
                .unsafeFlags(["-I\(swiftUIShimSearchPath)"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
