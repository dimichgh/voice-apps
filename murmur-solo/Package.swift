// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MurmurSolo",
    platforms: [.macOS(.v13)],
    targets: [
        // C module exposing whisper.cpp's headers. The compiled code lives in a
        // prebuilt static archive (Frameworks/whisper/lib/libwhisper_all.a),
        // linked below — built from ext/whisper.cpp via build-whisper.sh.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper"
        ),
        .executableTarget(
            name: "MurmurSolo",
            dependencies: ["CWhisper"],
            path: "Sources/MurmurSolo",
            linkerSettings: [
                // -force_load (not -lwhisper_all): ggml's Metal backend and the
                // embedded Metal shader register through the backend registry,
                // not through symbols our Swift code names — plain -l lets the
                // linker dead-strip them, silently leaving a CPU-only build.
                // force_load keeps every object; the only cost is a larger binary.
                .unsafeFlags(["-Xlinker", "-force_load", "-Xlinker", "Frameworks/whisper/lib/libwhisper_all.a"]),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
