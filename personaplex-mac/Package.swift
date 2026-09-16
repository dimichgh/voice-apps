// swift-tools-version: 5.10

import PackageDescription

// Forked from speech-swift's Examples/PersonaPlexDemo (Apache-2.0). Differences:
//   * no Qwen3ASR — full-duplex never used it, and a second MLX model on
//     another thread is the documented crash case
//   * runtime picker between the 8-bit and 4-bit PersonaPlex builds
//   * weights read from the local HF cache (mlxmgr snapshots), never downloaded
//   * per-step latency HUD against the 80ms frame budget
//   * free-text persona prompt instead of hardcoded token arrays
let package = Package(
    name: "PersonaPlexMac",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(path: "../ext/speech-swift"),
        // Same requirement speech-swift declares, so SwiftPM resolves one copy.
        // Needed directly so we can bound MLX's buffer cache — see
        // `boundMLXCache()`. PersonaPlex is the one model in the library that
        // sets no cache limit of its own.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
    ],
    targets: [
        .executableTarget(
            name: "PersonaPlexMac",
            dependencies: [
                .product(name: "PersonaPlex", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources",
            exclude: ["PersonaPlexDemo.entitlements", "Info.plist"]
        ),
    ]
)
