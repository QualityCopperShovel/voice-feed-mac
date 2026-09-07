// swift-tools-version: 5.9
import PackageDescription

// This package has no third-party dependencies. It builds one native executable
// against the macOS SDK already supplied by Apple's command-line tools.
let package = Package(
    name: "VoiceFeedMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VoiceFeedMac", targets: ["VoiceFeedMac"]),
    ],
    targets: [
        .executableTarget(name: "VoiceFeedMac"),
    ]
)
