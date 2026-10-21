// swift-tools-version:5.10
import PackageDescription

// Two targets on purpose: PlayerCore is pure logic (display order, show files,
// sync arithmetic) with no AppKit and no AVFoundation playback, so `swift test`
// can check it without a screen. The app target is the thin shell that turns
// that logic into windows and players.
let package = Package(
    name: "MultiscreenPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PlayerCore"),
        .executableTarget(name: "MultiscreenPlayer", dependencies: ["PlayerCore"]),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"]),
    ]
)
