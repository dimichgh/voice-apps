// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MurmurWK",
    platforms: [.macOS(.v14)],
    dependencies: [
        // WhisperKit lives in the argmax-oss-swift monorepo; the classic
        // WhisperKit repo URL serves the same package manifest.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "MurmurWK",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MurmurWK"
        ),
    ]
)
