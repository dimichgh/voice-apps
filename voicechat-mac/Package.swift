// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceChat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VoiceChat",
            path: "Sources/VoiceChat"
        ),
    ]
)
