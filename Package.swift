// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "VoiceFeedMac", platforms: [.macOS(.v13)], products: [.executable(name: "VoiceFeedMac", targets: ["VoiceFeedMac"])], targets: [.executableTarget(name: "VoiceFeedMac")])
