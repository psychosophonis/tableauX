// compose-time.swift — falsification probe for the repeated-composition item.
//
// IDEA AT RISK: building each panel's item as the clip repeated end to end in
// an AVMutableComposition (enough copies for 24 h, capped at
// Playback.maxSegments = 2000) is fast enough that Play starts promptly, and
// the result becomes playable.
//
// WHY IT MIGHT BE WRONG: Playback.makeItem awaits one insertTimeRange per copy,
// so a short clip means up to 2000 sequential calls into AVFoundation, and a
// 2000-segment composition may be slow for the player to load. The app logs
// nothing while it does this, so a slow build looks like "black screens, never
// starts". Seen 2026-10-21: two long 4K exports, Play pressed, it didn't start.
//
// WHAT WOULD FALSIFY IT: build time, or time to .readyToPlay, of more than a
// few seconds for the copy counts the app really uses.
//
// No windows, no playback: this tests the build alone, the same way the app
// does it (same calls, same order), so it can run without taking over screens.
//
//   swiftc -O proofs/compose-time.swift -o .build/compose-time
//   .build/compose-time testmedia/noise-3840x2160-10s.mp4 [copies...]

import AVFoundation

setvbuf(stdout, nil, _IONBF, 0)

@MainActor func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { print("usage: compose-time file [copies...]"); exit(2) }
    let url = URL(fileURLWithPath: args.removeFirst())
    let counts = args.isEmpty ? [1, 24, 288, 2000] : args.compactMap { Int($0) }

    let asset = AVURLAsset(url: url)
    let clip = try await asset.load(.duration)
    print("clip: \(url.lastPathComponent), \(String(format: "%.1f", clip.seconds)) s")

    for n in counts {
        let t0 = Date()
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: clip)
        for k in 0..<n {
            try await comp.insertTimeRange(range, of: asset, at: CMTimeMultiply(clip, multiplier: Int32(k)))
        }
        let built = Date().timeIntervalSince(t0)

        // Readiness is a separate cost: the player has to load the composition.
        let item = AVPlayerItem(asset: comp)
        let player = AVPlayer(playerItem: item)
        let t1 = Date()
        while item.status == .unknown && Date().timeIntervalSince(t1) < 120 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = Date().timeIntervalSince(t1)
        let status = item.status == .readyToPlay ? "ready" : item.status == .failed ? "FAILED \(item.error as Any)" : "still loading"
        print(String(format: "%5d copies: build %7.2f s, then %6.2f s to %@", n, built, ready, status))
        _ = player
    }
}

Task { @MainActor in
    do { try await run(); exit(0) } catch { print("error: \(error)"); exit(2) }
}
RunLoop.main.run()
