// swift-tools-version: 5.9
import PackageDescription

// This package has no third-party dependencies. It builds one native executable
// against the macOS SDK already supplied by Apple's command-line tools.
let package = Package(
    name: "VoiceFeedMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VoiceFeedMac", targets: ["VoiceFeedMac"]),
        .executable(name: "VoiceFeedAudioRecovery", targets: ["VoiceFeedAudioRecovery"]),
    ],
    targets: [
        .target(name: "CaptureCore"),
        .target(name: "CommandRunner", publicHeadersPath: "include"),
        .target(name: "AudioRecoveryProtocol"),
        .executableTarget(name: "VoiceFeedAudioRecovery", dependencies: ["CaptureCore", "AudioRecoveryProtocol"]),
        .target(name: "AudioSafety", publicHeadersPath: "include"),
        .target(name: "CaptureAudio", dependencies: ["AudioSafety", "CaptureCore"]),
        .testTarget(name: "CaptureAudioTests", dependencies: ["CaptureAudio", "AudioSafety", "CaptureCore"]),
        .executableTarget(name: "VoiceFeedMac", dependencies: ["CaptureCore", "CaptureAudio", "AudioSafety", "AudioRecoveryProtocol", "CommandRunner"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
    ]
)
