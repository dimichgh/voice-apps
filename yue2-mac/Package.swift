// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "YuE2",
    platforms: [.macOS(.v26)],   // Liquid Glass APIs (glassEffect, ToolbarSpacer, backgroundExtensionEffect)
    targets: [
        .executableTarget(
            name: "YuE2",
            path: "Sources/YuE2",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
