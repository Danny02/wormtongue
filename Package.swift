// swift-tools-version: 6.0
import PackageDescription

// The package is split so the parts with real edge cases can be built and tested
// off a Mac:
//
//   VoiceModeCore — Foundation only. Config decoding, mode resolution, the
//                   privacy policy, prompt assembly, the context tail buffer,
//                   and Anthropic request/response coding. Has tests.
//   VoiceMode     — the app. AppKit, Accessibility, AVFoundation, WhisperKit.
//
// The macOS target and its dependencies are declared only when the manifest is
// evaluated on macOS. Package.swift is ordinary Swift code, so on Linux the
// graph collapses to Core + tests with no external dependencies to resolve —
// `swift build` and `swift test` work there with no network access.
#if os(macOS)
    // The on-device rewrite pass is opt-in at build time: MLX is a large
    // dependency and the models are multi-GB downloads, so a default build stays
    // light and the first build is as likely to succeed as possible. Enable with
    // `./Scripts/bundle.sh release --local-pass`, or set the variable directly.
    let localPass = ProcessInfo.processInfo.environment["VOICEMODE_LOCAL_PASS"] == "1"

    var platformDependencies: [Package.Dependency] = [
        // WhisperKit now ships from the consolidated argmax-oss-swift package.
        // github.com/argmaxinc/WhisperKit redirects here.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.0"),
    ]

    var appDependencies: [Target.Dependency] = [
        "VoiceModeCore",
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
        "KeyboardShortcuts",
    ]

    // Swift 6 toolchain, language mode 5: the AX C API, CGEvent, and the
    // AVAudioEngine tap callback all cross isolation boundaries in ways strict
    // concurrency checking rejects. Core is checked strictly.
    var appSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

    if localPass {
        // Note: this package's own manifest requires Swift 6.1, so a --local-pass
        // build needs a 6.1+ toolchain even though ours declares 6.0.
        platformDependencies.append(
            .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"))
        appDependencies.append(contentsOf: [
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        ])
        appSwiftSettings.append(.define("VOICEMODE_LOCAL_PASS"))
    }

    let platformTargets: [Target] = [
        .executableTarget(
            name: "VoiceMode",
            dependencies: appDependencies,
            swiftSettings: appSwiftSettings
        )
    ]
#else
    let platformDependencies: [Package.Dependency] = []
    let platformTargets: [Target] = []
#endif

let package = Package(
    name: "VoiceMode",
    platforms: [.macOS(.v14)],
    dependencies: platformDependencies,
    targets: [
        .target(name: "VoiceModeCore"),
        .testTarget(name: "VoiceModeCoreTests", dependencies: ["VoiceModeCore"]),
    ] + platformTargets
)
