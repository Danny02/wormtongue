// swift-tools-version: 6.0
import PackageDescription

// The package is split so the parts with real edge cases can be built and tested
// off a Mac:
//
//   VoiceModeCore — Foundation only. Config decoding, mode resolution, the
//                   privacy policy, prompt assembly, the context tail buffer,
//                   and Anthropic request/response coding. Has tests.
//   VoiceMode     — the app. AppKit, Accessibility, AVFoundation, WhisperKit.
//   CamelCup      — Foundation only. The Camel Cup dice cup, plus the `camelcup`
//                   command line simulator. Unrelated to dictation; it builds
//                   and tests anywhere.
//
// The macOS target and its dependencies are declared only when the manifest is
// evaluated on macOS. Package.swift is ordinary Swift code, so on Linux the
// graph collapses to Core + tests with no external dependencies to resolve —
// `swift build` and `swift test` work there with no network access.
#if os(macOS)
    let platformDependencies: [Package.Dependency] = [
        // WhisperKit now ships from the consolidated argmax-oss-swift package.
        // github.com/argmaxinc/WhisperKit redirects here.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.0"),
    ]

    let platformTargets: [Target] = [
        .executableTarget(
            name: "VoiceMode",
            dependencies: [
                "VoiceModeCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "KeyboardShortcuts",
            ],
            // Swift 6 toolchain, language mode 5: the AX C API, CGEvent, and the
            // AVAudioEngine tap callback all cross isolation boundaries in ways
            // strict concurrency checking rejects. Core is checked strictly.
            swiftSettings: [.swiftLanguageMode(.v5)]
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
        // Camel Cup dice: Foundation only, independent of the dictation app.
        .target(name: "CamelCup"),
        .executableTarget(name: "camelcup", dependencies: ["CamelCup"]),
        .testTarget(name: "CamelCupTests", dependencies: ["CamelCup"]),
    ] + platformTargets
)
