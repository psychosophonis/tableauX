// empty-range-probe.swift — falsification probe for v4 P2 ("shorter: black").
//
// IDEA AT RISK (docs/architecture.md § v4 › Playing): a screen whose file is
// shorter than its work can go black after its file ends, and start again at
// the next play of the work, using ONE player item laid out as
//     [clip][empty time up to the work's length] … [clip]
// so the item's own clock is always "seconds into the work". If that holds,
// starting, joining late and the drift check need no special case for black
// screens: they already ask the item to be at "seconds into the work".
//
// FIRST RUN (2026-10-21) FALSIFIED THE FIRST FORM, [clip][empty] × plays: an
// empty range at the END of a composition is dropped (layout 6.00 s, the
// composition 4.00 s), so the item ended early, the player stopped, and
// would have held its last frame on screen. Empty ranges BETWEEN clips
// behaved (no frames, time ran on, a start inside one worked). So the layout
// now ends on a clip, and the black after the last play is the app's job:
// when an item ends before its work does, the app hides that screen. Check 5
// tests the signal it relies on for that.
//
// WHAT WOULD FALSIFY IT (set before running):
//   1. the composition isn't as long as the layout (now with no trailing empty);
//   2. the player's time doesn't keep advancing at rate 1 through the empty
//      range between clips;
//   3. frames keep arriving during an empty range (the decoder is still
//      producing pictures, i.e. something other than black);
//   4. a start scheduled INSIDE an empty range doesn't deliver the next
//      clip's frames when the timeline reaches it;
//   5. the item's end notification doesn't arrive within 0.1 s of the
//      item's end (the app's cue to hide a finished screen).
//
// WHAT IT CAN'T TELL: what AVPlayerLayer draws during an empty range. With no
// frames it should draw nothing (its black background), but that is checked
// by eye in the app run, not here.
//
// Build and run:
//   swiftc -O proofs/empty-range-probe.swift -o .build/empty-range-probe
//   .build/empty-range-probe testmedia/panel1-1920x1080-1s.mp4

import AVFoundation

setvbuf(stdout, nil, _IONBF, 0)
let hostClock = CMClockGetHostTimeClock()
func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1_000_000_000) }

/// [clip][empty `gap`][clip]…, `plays` clips, built the way the app will
/// build it: on the composition's own track, so the empty ranges are real
/// track edits.
func layout(_ asset: AVURLAsset, clip: CMTime, gap: Double, plays: Int) async throws -> AVMutableComposition {
    let comp = AVMutableComposition()
    let src = try await asset.loadTracks(withMediaType: .video)[0]
    let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    var cursor = CMTime.zero
    for k in 0..<plays {
        if k > 0 {
            track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: cm(gap)))
            cursor = cursor + cm(gap)
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: clip), of: src, at: cursor)
        cursor = cursor + clip
    }
    return comp
}

struct Watched { var samples: [(t: Double, rate: Float, frame: Bool)] = []; var endedLate: Double? }

/// Plays the composition from item time `from` and, every 20 ms for
/// `seconds`, records the item time, the rate and whether a new frame
/// arrived; also how late the end notification came after the item's end.
@MainActor func watch(_ comp: AVMutableComposition, from: Double, seconds: Double) async -> Watched {
    let item = AVPlayerItem(asset: comp)
    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(out)
    let p = AVPlayer(playerItem: item)
    p.automaticallyWaitsToMinimizeStalling = false
    p.masterClock = hostClock
    p.actionAtItemEnd = .pause          // as the app: hold at the end, don't advance
    while item.status != .readyToPlay { try? await Task.sleep(for: .milliseconds(10)) }
    _ = await p.preroll(atRate: 1)
    let h0 = CMClockGetTime(hostClock).seconds + 0.2
    var w = Watched()
    let end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
        // Where the end should be, on the host clock: start + (duration − from).
        let due = h0 + comp.duration.seconds - from
        MainActor.assumeIsolated { w.endedLate = CMClockGetTime(hostClock).seconds - due }
    }
    p.setRate(1, time: cm(from), atHostTime: cm(h0))
    try? await Task.sleep(for: .milliseconds(200))
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        let host = CMClockGetTime(hostClock)
        let t = out.itemTime(forHostTime: host.seconds)
        let fresh = out.hasNewPixelBuffer(forItemTime: t) && out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil
        w.samples.append((p.currentTime().seconds, p.rate, fresh))
        try? await Task.sleep(for: .milliseconds(20))
    }
    NotificationCenter.default.removeObserver(end)
    p.pause()
    return w
}

@MainActor func run() async throws -> Int32 {
    guard CommandLine.arguments.count == 2 else { print("usage: empty-range-probe clip.mp4"); return 2 }
    let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let clip = try await asset.load(.duration)
    let d = clip.seconds, gap = 2.0, plays = 2
    let comp = try await layout(asset, clip: clip, gap: gap, plays: plays)
    var ok = true

    // 1. Length.
    let want = d * Double(plays) + gap * Double(plays - 1)
    print(String(format: "clip %.2f s; layout %.2f s; composition %.2f s", d, want, comp.duration.seconds))
    if abs(comp.duration.seconds - want) > 0.01 { print("✗ 1: the composition is not as long as the layout"); ok = false }

    // 2, 3, 5. Play the whole thing from 0, and on past its end. Phases by
    // item time; 0.1 s margins allow for frames timed right at an edge.
    let run = await watch(comp, from: 0, seconds: want + 0.3)
    func phase(_ t: Double) -> String? {
        let x = t.truncatingRemainder(dividingBy: d + gap)
        if x > 0.1 && x < d - 0.1 { return "clip" }
        if x > d + 0.1 && x < d + gap - 0.1 && t < want - 0.1 { return "empty" }
        return nil
    }
    let inside = run.samples.filter { $0.t < want - 0.1 }
    let clipFrames = inside.filter { phase($0.t) == "clip" && $0.frame }.count
    let emptySamples = inside.filter { phase($0.t) == "empty" }
    let emptyFrames = emptySamples.filter(\.frame).count
    let stopped = inside.filter { $0.rate == 0 }.count
    print(String(format: "before the end: %d samples, %d at rate 0; item time ran to %.2f s", inside.count, stopped, inside.last?.t ?? 0))
    print("frames: \(clipFrames) during clips, \(emptyFrames) during \(emptySamples.count) samples of the empty range")
    if stopped > 0 || (inside.last?.t ?? 0) < want - 0.2 { print("✗ 2: time did not run through the empty range"); ok = false }
    if emptySamples.isEmpty || emptyFrames > 0 { print("✗ 3: frames arrived during the empty range (or it was never sampled)"); ok = false }
    if clipFrames == 0 { print("✗ (setup) no frames at all: the probe sees nothing"); ok = false }
    if let late = run.endedLate {
        print(String(format: "end notification %.1f ms after the item's end", late * 1000))
        if abs(late) > 0.1 { print("✗ 5: the end notification is too far from the end"); ok = false }
    } else { print("✗ 5: no end notification"); ok = false }

    // 4. Start inside the empty range; the second clip must arrive.
    let late = await watch(comp, from: d + 0.5, seconds: gap)
    let second = late.samples.filter { phase($0.t) == "clip" && $0.frame }.count
    print(String(format: "started inside the empty range at %.2f s: %d frames of the next clip", d + 0.5, second))
    if second == 0 { print("✗ 4: a start inside an empty range never showed the next clip"); ok = false }

    print(ok ? "✓ survived: one item per screen, black as empty time between plays, item end = black after the last" : "✗ FALSIFIED")
    return ok ? 0 : 1
}

Task { @MainActor in
    do { exit(try await run()) } catch { print("error: \(error)"); exit(2) }
}
RunLoop.main.run()
