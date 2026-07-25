// swift-tools-version: 6.0
import PackageDescription

// Swift 6 toolchain, but language mode 5: the AX C API, CGEvent, and the
// AVAudioEngine tap callback all cross isolation boundaries in ways strict
// concurrency checking rejects. Prototype first, Sendable audit later.
let package = Package(
    name: "VoiceMode",
    platforms: [.macOS(.v14)],
    dependencies: [
        // WhisperKit now ships from the consolidated argmax-oss-swift package.
        // github.com/argmaxinc/WhisperKit redirects here.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceMode",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "KeyboardShortcuts",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
