import AppKit
import AVFoundation
import IOKit.pwr_mgt
import PlayerCore

/// A borderless window that covers one display during playback.
///
/// Borderless windows normally refuse keyboard focus; overriding canBecomeKey
/// lets Space and Esc reach us. Keys go to a closure instead of each window
/// knowing about playback, so the window stays a dumb surface.
final class PanelWindow: NSWindow {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

/// One panel during playback.
@MainActor
private final class LivePanel {
    let window: PanelWindow
    let player: AVPlayer?           // nil = this display just stays black
    let itemDuration: Double        // the whole repeated item, not one clip
    let frame: Double               // one frame, in seconds
    var corrections = 0
    var gate: DriftGate             // [claude] the grace period, per panel (§ Sync)

    init(window: PanelWindow, player: AVPlayer?, itemDuration: Double, frame: Double, grace: Double) {
        self.window = window; self.player = player; self.itemDuration = itemDuration; self.frame = frame
        self.gate = DriftGate(grace: grace)
    }
}

/// Runs one show: a window per display, a player per panel, one shared clock.
///
/// The sync design, which `proofs/sync-probe.swift` tested before this was
/// built (docs/architecture.md § Sync):
///  1. Every player follows the HOST CLOCK (masterClock), so all of them count
///     time from the same source and can't drift relative to each other.
///  2. All players get the same start instant `h0`, a moment slightly in the
///     future, through setRate(_:time:atHostTime:). Scheduling ahead absorbs
///     the time it takes to tell each player in turn, so they all start together.
///  3. Each item is the clip repeated end to end, so looping is a continuous
///     stream with no seek at the loop point.
///  4. Once a second a CLOSED-LOOP CHECK compares each panel with where the
///     shared clock says it should be, and re-syncs any panel that has been
///     more than the show's tolerance out for its grace period (default 3
///     frames, 5 s; a stalled panel at once). Steps 1–3 should make this rare;
///     the check catches what they don't, such as a stall or a capped item
///     running out.
@MainActor
final class Playback {
    /// Each item covers this much time before it needs a resync (docs/architecture.md).
    static let cover: Double = 24 * 3600
    static let maxSegments = 2_000

    private let assignments: [(NSScreen, PanelConfig)]
    private let sync: SyncSettings
    private let onWindowsUp: () -> Void
    private let onEnd: () -> Void
    private var panels: [LivePanel] = []
    // [claude] Every window this show has opened, tracked from the moment it is
    // built. `panels` only gains a window once its video has loaded, so a stop
    // during loading (Esc, a failed file, a display change) used to leave the
    // rest of the black windows covering the screens.
    private var windows: [PanelWindow] = []
    private let hostClock = CMClockGetHostTimeClock()
    private var h0 = 0.0                 // shared start, host-clock seconds
    private var pausedAt: Double?        // host time we paused at, if paused
    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    private var stopped = false
    private var started = false          // true once the shared start is scheduled

    /// `onWindowsUp` runs once every panel window is on screen; `onEnd` runs
    /// when the show stops, before its windows close.
    ///
    /// [claude] The two callbacks exist to keep one invariant: SOME WINDOW IS
    /// ALWAYS VISIBLE. AppKit treats hiding or closing the last visible window
    /// as "last window closed", and the app is set to quit then. The first
    /// version hid the setup window before the panel windows existed, and the
    /// app quit the moment Play was pressed (confirmed with a diagnostic log on
    /// 2026-10-21). So the hand-over goes: new windows up, then old ones away.
    init(assignments: [(NSScreen, PanelConfig)],
         sync: SyncSettings,
         onWindowsUp: @escaping () -> Void,
         onEnd: @escaping () -> Void) {
        self.assignments = assignments
        self.sync = sync
        self.onWindowsUp = onWindowsUp
        self.onEnd = onEnd
    }

    private func hostNow() -> Double { CMClockGetTime(hostClock).seconds }
    private func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1_000_000_000) }

    func start() async throws {
        // [claude] STAGE LOGGING: one line per step of the start sequence, each
        // stamped with the time since Play. A start that never happens then
        // says where it stopped (and how long each step took), instead of
        // leaving black screens and no clue. Added after a real start failed
        // silently on 2026-10-21.
        let t0 = Date()
        func stage(_ s: String) { NSLog("start +%.2fs: %@", Date().timeIntervalSince(t0), s) }

        // Build windows first, so every display goes black at once even while
        // the videos are still loading.
        var built: [(PanelWindow, PanelConfig)] = []
        for (screen, config) in assignments {
            let w = makeWindow(on: screen)
            windows.append(w)
            built.append((w, config))
        }
        stage("\(built.count) window(s) up")
        onWindowsUp()
        NSCursor.hide()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "tableauX is playing" as CFString, &sleepAssertion)

        for (window, config) in built {
            guard let path = config.file else {
                panels.append(LivePanel(window: window, player: nil, itemDuration: 0, frame: 1.0 / 30, grace: sync.grace))
                continue
            }
            let (item, itemDuration, fps) = try await Self.makeItem(URL(fileURLWithPath: path))
            stage(String(format: "item built: %@ (%.0f fps, item %.0f s)",
                         (path as NSString).lastPathComponent, fps, itemDuration))
            if stopped { stage("stopped before the start finished"); return }
            let player = AVPlayer(playerItem: item)
            // Needed for setRate(_:time:atHostTime:), which won't schedule a start
            // on a player that's allowed to wait for buffering.
            player.automaticallyWaitsToMinimizeStalling = false
            player.masterClock = hostClock
            player.isMuted = !config.audio
            // At the very end of a (capped) item, hold still rather than advance;
            // the drift check sees the stopped panel and restarts it in sync.
            player.actionAtItemEnd = .pause
            attach(player, to: window, scaling: config.scaling)
            panels.append(LivePanel(window: window, player: player, itemDuration: itemDuration,
                                    frame: 1 / max(fps, 1), grace: sync.grace))
        }

        // Wait for every item to be ready, then PREROLL: decode the first frames
        // ahead so the start is only a clock being released, not a cold decode.
        let players = panels.compactMap(\.player)
        while let pending = players.first(where: { $0.currentItem?.status != .readyToPlay }) {
            if pending.currentItem?.status == .failed { throw pending.currentItem?.error ?? CocoaError(.fileReadCorruptFile) }
            try await Task.sleep(for: .milliseconds(20))
            if stopped { stage("stopped before the start finished"); return }
        }
        stage("all \(players.count) item(s) ready to play")
        for (i, p) in players.enumerated() {
            let ok = await p.preroll(atRate: 1)
            stage("preroll \(i + 1): \(ok ? "done" : "interrupted")")
        }
        if stopped { stage("stopped before the start finished"); return }

        h0 = hostNow() + 1
        for p in players { p.setRate(1, time: .zero, atHostTime: cm(h0)) }
        started = true
        stage("start scheduled 1 s ahead")

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDrift() }
        }
    }

    /// The clip repeated end to end in one composition, so the loop point is
    /// just the next segment in a continuous timeline (see SyncMath.repeats).
    private static func makeItem(_ url: URL) async throws -> (AVPlayerItem, Double, Double) {
        let asset = AVURLAsset(url: url)
        let clip = try await asset.load(.duration)
        let fps = Double(try await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate) ?? 30)
        let n = SyncMath.repeats(duration: clip.seconds, cover: cover, maxSegments: maxSegments)
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: clip)
        for k in 0..<n {
            try await comp.insertTimeRange(range, of: asset, at: CMTimeMultiply(clip, multiplier: Int32(k)))
        }
        // Carry the file's rotation flag over to the composition's video track,
        // or phone footage shot upright would play sideways.
        if let src = try await asset.loadTracks(withMediaType: .video).first,
           let dst = comp.tracks(withMediaType: .video).first {
            dst.preferredTransform = try await src.load(.preferredTransform)
        }
        return (AVPlayerItem(asset: comp), CMTimeMultiply(clip, multiplier: Int32(n)).seconds, fps)
    }

    private func makeWindow(on screen: NSScreen) -> PanelWindow {
        let w = PanelWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        // Above the menu bar and Dock on every display. .screenSaver is the
        // level macOS itself uses for things that must cover everything.
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.setFrame(screen.frame, display: true)
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        w.onKey = { [weak self] e in self?.handle(e) }
        w.makeKeyAndOrderFront(nil)
        return w
    }

    private func attach(_ player: AVPlayer, to window: PanelWindow, scaling: Scaling) {
        guard let view = window.contentView, let root = view.layer else { return }
        let layer = AVPlayerLayer(player: player)
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // ASPECT GRAVITY: uniform scaling, so the image never stretches.
        // resizeAspect = fit (letterbox), resizeAspectFill = fill (crop).
        layer.videoGravity = scaling == .fit ? .resizeAspect : .resizeAspectFill
        // Render at the display's real pixel density, so a 4K screen gets 4K detail.
        layer.contentsScale = window.screen?.backingScaleFactor ?? 2
        layer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(layer)
    }

    private func handle(_ e: NSEvent) {
        switch e.keyCode {
        case 53: stop()                  // Esc
        case 49: togglePause()           // Space
        default: break
        }
    }

    private func togglePause() {
        // [claude] Nothing to pause until the start is scheduled. Earlier, a
        // Space while files were still loading paused the players built so far,
        // then start() scheduled them anyway: playing, but marked as paused.
        guard started else { return }
        let players = panels.compactMap(\.player)
        if let paused = pausedAt {
            // Resume: shift the shared start by however long we were paused, then
            // restart every panel at the same future instant.
            let h1 = hostNow() + 0.5
            h0 = SyncMath.resumedStart(start: h0, pausedAt: paused, resumeAt: h1)
            for p in panels { if let pl = p.player { pl.setRate(1, time: cm(expected(p, at: h1)), atHostTime: cm(h1)) } }
            pausedAt = nil
        } else {
            let now = hostNow()
            players.forEach { $0.pause() }
            pausedAt = now
        }
    }

    private func expected(_ p: LivePanel, at host: Double) -> Double {
        SyncMath.expected(host: host, start: h0, duration: p.itemDuration)
    }

    /// Once a second: is every panel where the shared clock says it should be?
    private func checkDrift() {
        guard pausedAt == nil else { return }
        let now = hostNow()
        for p in panels {
            guard let player = p.player, let tb = player.currentItem?.timebase else { continue }
            // Read the panel's time at exactly `now` by converting that host
            // instant into the panel's own timebase, not by asking "what time is
            // it?" a few microseconds later for each panel in turn.
            let actual = CMSyncConvertTime(cm(now), from: hostClock, to: tb).seconds
            let stalled = player.rate == 0
            let out = SyncMath.needsCorrection(actual: actual, expected: expected(p, at: now),
                                               duration: p.itemDuration, frame: p.frame, tolerance: sync.tolerance)
            // A stalled panel is frozen, not drifting: waiting out the grace
            // period would only leave a still picture on screen for longer.
            // The gate is checked first so it sees every check either way.
            if p.gate.check(out: out, now: now) || stalled {
                let h1 = now + 0.5
                player.setRate(1, time: cm(expected(p, at: h1)), atHostTime: cm(h1))
                p.corrections += 1
                NSLog("panel resynced (\(stalled ? "stalled" : String(format: "%.1f ms out", abs(actual - expected(p, at: now)) * 1000)))")
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        for p in panels { p.player?.pause() }
        NSApp.presentationOptions = []
        NSCursor.unhide()
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
        // Take the windows into a local first: onEnd() drops AppModel's
        // reference to this Playback, which may free it, so nothing below that
        // call may touch `self`.
        let ours = windows
        windows = []
        panels = []
        // Bring the setup window back BEFORE closing ours (see init): closing
        // the panel windows first would leave no visible window, and the app
        // would quit at the end of every show.
        onEnd()
        for w in ours {
            w.orderOut(nil)
            w.close()
        }
    }
}
