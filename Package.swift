// swift-tools-version:5.10
import PackageDescription

// Two targets on purpose: PlayerCore is pure logic (display order, show files,
// sync arithmetic) with no AppKit and no AVFoundation playback, so `swift test`
// can check it without a screen. The app target is the thin shell that turns
// that logic into windows and players.
let package = Package(
    name: "tableauX",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PlayerCore"),
        // The executable target's name is the binary's name, and so the process
        // name macOS shows and logs under.
        .executableTarget(name: "tableauX", dependencies: ["PlayerCore"]),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"]),
    ]
)
