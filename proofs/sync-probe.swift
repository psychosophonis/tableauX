// sync-probe.swift — falsification probe for the player's sync design.
//
// IDEA AT RISK: separate AVPlayers, each slaved to the host clock and started
// with setRate(_:time:atHostTime:) on one shared host time, stay within one
// frame of each other indefinitely — including across loops, when each item is
// the clip repeated end to end in an AVMutableComposition — and 3 × 4K decodes
// in real time without dropping frames.
//
// WHAT WOULD FALSIFY IT (targets T1, T2, T4 in docs/architecture.md):
//   - start skew between panels > 1 frame, or
//   - skew that grows over a long run (drift), or
//   - frames missing from any panel's decoded output (dropped frames).
//
// HOW THIS TRIES TO KILL IT: play N files with no display, read every panel's
// clock at the SAME host instant (CMSyncConvertTime, so polling order doesn't
// add error), and pull every decoded frame through AVPlayerItemVideoOutput,
// checking the frame numbers have no gaps.
//
// THE CONTROL: --control plays the last panel 0.1% fast. That must FAIL (about
// 1 frame of drift every 33 s). If the control passes, the probe can't see drift
// and its PASS on a real run means nothing. A probe that can't fail proves nothing.
//
// WHAT IT DOESN'T TEST: when each display actually shows its frame. Separate
// displays refresh on their own schedules, so presentation can differ by up to
// one refresh. That needs the real array (target T6, docs/LAB-TEST.md).
//
// Build and run (compiled with -O, so the probe's own overhead stays small):
//   swiftc -O proofs/sync-probe.swift -o .build/sync-probe
//   .build/sync-probe [--seconds 120] [--control] file1 file2 ...

import AVFoundation
import CoreMedia

setvbuf(stdout, nil, _IONBF, 0)
let hostClock = CMClockGetHostTimeClock()
func hostNow() -> CMTime { CMClockGetTime(hostClock) }

/// One panel: its player, its decoded-frame tap, and what we've seen from it.
final class Panel {
    let name: String
    let player: AVPlayer
    let output: AVPlayerItemVideoOutput
    let fps: Double
    var frames = 0
    var dropped = 0
    var lastIndex: Int?
    init(name: String, player: AVPlayer, output: AVPlayerItemVideoOutput, fps: Double) {
        self.name = name; self.player = player; self.output = output; self.fps = fps
    }
}

/// The probe runs on the MAIN ACTOR, and the main thread runs the run loop
/// (bottom of file). AVFoundation reports player status on the main queue, so
/// the main thread must stay free to drain it. Each `Task.sleep` below hands the
/// thread back so it can. Blocking the main thread while waiting for a status
/// change is a DEADLOCK: the status can never arrive.
@MainActor func run() async throws -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    var seconds = 120.0
    var control = false
    if let i = args.firstIndex(of: "--seconds") { seconds = Double(args[i + 1])!; args.removeSubrange(i...i + 1) }
    if let i = args.firstIndex(of: "--control") { control = true; args.remove(at: i) }
    guard !args.isEmpty else { print("usage: sync-probe [--seconds N] [--control] files…"); return 2 }

    // Build each panel. The item is the clip repeated end to end (a REPEATED
    // COMPOSITION) rather than seeking back to zero at the end of each loop: a
    // seek is a discontinuity (a gap, plus a fresh decode from the keyframe),
    // while a composition is one continuous timeline the decoder streams straight
    // through. Continuity also makes sync checkable: item time = host time − start.
    var panels: [Panel] = []
    for path in args {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { print("no video: \(path)"); return 2 }
        let fps = Double(try await track.load(.nominalFrameRate))
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        let repeats = Int((seconds + 10) / duration.seconds) + 1
        for k in 0..<repeats {
            try await comp.insertTimeRange(range, of: asset, at: CMTimeMultiply(duration, multiplier: Int32(k)))
        }
        let item = AVPlayerItem(asset: comp)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        // Required for setRate(_:time:atHostTime:): the player must not hold off
        // starting while it buffers, or the scheduled start would be ignored.
        player.automaticallyWaitsToMinimizeStalling = false
        // Slave every player to the same clock (the host clock), so none of them
        // follows a different one, such as its own audio device.
        player.masterClock = hostClock
        panels.append(Panel(name: URL(fileURLWithPath: path).lastPathComponent, player: player, output: output, fps: fps))
    }

    // Wait until every item can play, then PREROLL: decode the first frames
    // ahead of time, so starting is just releasing a clock, not a cold decode.
    while panels.contains(where: { $0.player.currentItem?.status != .readyToPlay }) {
        if let failed = panels.first(where: { $0.player.currentItem?.status == .failed }) {
            print("failed: \(failed.name) \(failed.player.currentItem?.error as Any)"); return 2
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    for p in panels { _ = await p.player.preroll(atRate: 1) }

    // The shared start: one host time, one second ahead, handed to every player.
    let h0 = CMTimeAdd(hostNow(), CMTime(seconds: 1, preferredTimescale: 1_000_000_000))
    for (i, p) in panels.enumerated() {
        let rate: Float = (control && i == panels.count - 1) ? 1.001 : 1
        p.player.setRate(rate, time: .zero, atHostTime: h0)
    }

    let frame = 1 / (panels.first?.fps ?? 30)
    var maxSkew = 0.0, maxErr = 0.0
    var startSkew: Double?
    var nextSample = h0.seconds + 0.5
    let end = h0.seconds + seconds

    while hostNow().seconds < end {
        try await Task.sleep(for: .milliseconds(2))
        let now = hostNow()

        // Pull every new decoded frame. A gap in frame numbers = a dropped frame.
        for p in panels {
            let t = p.output.itemTime(forHostTime: now.seconds)
            if p.output.hasNewPixelBuffer(forItemTime: t) {
                var shown = CMTime.zero
                if p.output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) != nil {
                    let idx = Int((shown.seconds * p.fps).rounded())
                    if let last = p.lastIndex, idx > last + 1 { p.dropped += idx - last - 1 }
                    p.lastIndex = idx
                    p.frames += 1
                }
            }
        }

        // Read every panel's clock at the same host instant. CMSyncConvertTime
        // maps that one instant into each player's timebase, so it doesn't
        // matter which panel we ask first.
        if now.seconds >= nextSample {
            nextSample += 0.25
            let expected = now.seconds - h0.seconds
            let times = panels.compactMap { p -> Double? in
                guard let tb = p.player.currentItem?.timebase else { return nil }
                return CMSyncConvertTime(now, from: hostClock, to: tb).seconds
            }
            let skew = (times.max() ?? 0) - (times.min() ?? 0)
            if startSkew == nil { startSkew = skew }
            maxSkew = max(maxSkew, skew)
            maxErr = max(maxErr, times.map { abs($0 - expected) }.max() ?? 0)
        }
    }

    let ms = { (s: Double) in String(format: "%.2f ms", s * 1000) }
    print("panels: \(panels.count)   run: \(Int(seconds)) s   frame: \(ms(frame))\(control ? "   CONTROL: last panel at rate 1.001" : "")")
    print("start skew \(ms(startSkew ?? 0))   max skew \(ms(maxSkew))   max error vs host clock \(ms(maxErr))")
    for p in panels {
        print("  \(p.name): \(p.frames)/\(Int(seconds * p.fps)) frames, \(p.dropped) dropped")
    }
    let synced = (startSkew ?? 1) <= frame && maxSkew <= frame
    let noDrops = panels.allSatisfy { $0.dropped == 0 }
    print(synced && noDrops
          ? "✓ idea survived: in sync within one frame, no dropped frames."
          : "✗ idea FALSIFIED: \(synced ? "" : "skew exceeded one frame. ")\(noDrops ? "" : "frames were dropped.")")
    return synced && noDrops ? 0 : 1
}

Task { @MainActor in
    do { exit(try await run()) } catch { print("error: \(error)"); exit(2) }
}
RunLoop.main.run()
