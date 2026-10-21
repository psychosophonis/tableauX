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

/// [claude] One work's part on this Mac, ready to play (§ v4 › Model): its
/// panels with files resolved to full paths, and its timing.
struct WorkPart {
    let name: String
    let panels: [PanelConfig]       // index = this Mac's display - 1; files absolute
    let durations: [String: Double] // file → its length, for the item layout
    let length: Double              // one play: the work's longest file (0 = nothing here)
    let `repeat`: Repeat
    let shorter: Shorter
}

/// One panel during one work.
@MainActor
private final class LivePanel {
    let window: PanelWindow
    let player: AVPlayer?           // nil = this display just stays black
    let layer: AVPlayerLayer?
    let itemDuration: Double        // the whole laid-out item (ItemLayout)
    let wraps: Bool                 // [claude] an "until next" item repeats when it runs out, as v1's did
    let frame: Double               // one frame, in seconds
    var corrections = 0
    var gate: DriftGate             // [claude] the grace period, per panel (§ Sync)
    var finished = false            // [claude] its item ended before the work did: black until the work ends

    init(window: PanelWindow, player: AVPlayer?, layer: AVPlayerLayer?, itemDuration: Double, wraps: Bool, frame: Double, grace: Double) {
        self.window = window; self.player = player; self.layer = layer
        self.itemDuration = itemDuration; self.wraps = wraps; self.frame = frame
        self.gate = DriftGate(grace: grace)
    }
}

/// [claude] The players of the work on screen (or loading for the next).
@MainActor
private final class LoadedWork {
    let index: Int
    var begins: Double              // show time this play of the work starts
    let panels: [LivePanel]
    var scheduled = false           // its players have been told when to start
    var endObservers: [NSObjectProtocol] = []

    init(index: Int, begins: Double, panels: [LivePanel]) {
        self.index = index; self.begins = begins; self.panels = panels
    }
}

/// [claude] The show's clock, as seen from this Mac (§ v3 › Show state).
///
/// Playback keeps every time (a work's start, a pause, the drift check's
/// "where should it be") in SHOW TIME, and converts to this Mac's host clock
/// only at the last step, when it tells an AVPlayer when to start. This is an
/// ADAPTER: the same playback code runs standalone, as a conductor (show time
/// is host time) or as a player (show time is the conductor's clock, from the
/// estimate), with only this pair of conversions differing.
struct ShowClock {
    let toShow: (Double) -> Double?      // host seconds → show seconds; nil = no estimate yet
    let toHost: (Double) -> Double?

    static let local = ShowClock(toShow: { $0 }, toHost: { $0 })

    static func following(_ client: ClockClient) -> ShowClock {
        ShowClock(toShow: { client.conductorTime(host: $0) }, toHost: { client.hostTime(conductor: $0) })
    }
}

/// Runs one show: a window per display for the whole show, and per work a
/// player per panel, all on one shared clock.
///
/// The sync design, which `proofs/sync-probe.swift` tested before this was
/// built (docs/architecture.md § Sync):
///  1. Every player follows the HOST CLOCK (masterClock), so all of them count
///     time from the same source and can't drift relative to each other.
///  2. All players get the same start instant, a moment slightly in the
///     future, through setRate(_:time:atHostTime:). Scheduling ahead absorbs
///     the time it takes to tell each player in turn, so they all start together.
///  3. Each item is laid out so its own time is time into the work
///     (ItemLayout): looping is clips end to end, with no seek at the loop
///     point; "black" is empty time between plays.
///  4. Once a second a CLOSED-LOOP CHECK compares each panel with where the
///     shared clock says it should be, and re-syncs any panel that has been
///     more than the show's tolerance out for its grace period (default 3
///     frames, 5 s; a stalled panel at once).
///
/// [claude] v4 playlists (§ v4 › Playing, Timing): which work is on is a pure
/// function of the show time (`Timeline.segment`), given an ANCHOR ("work k
/// started at show time t0"). Playback asks the timeline what is on now and
/// when that ends, and sets one timer for the end. At each end it tears the
/// work's players down (black), builds the next work's during the gap, and
/// starts them at the work's start. Only a person (→, ←) moves the anchor.
/// The windows stay up throughout, so the screens never flash the desktop
/// and some window is always visible (see init).
@MainActor
final class Playback {
    /// An "until next" item covers this much time before it needs a resync (docs/architecture.md).
    static let cover: Double = 24 * 3600
    static let maxSegments = 2_000

    private let screens: [NSScreen]
    private let works: [WorkPart]
    private let timeline: Timeline
    private let sync: SyncSettings
    private let clock: ShowClock
    /// Set on a conductor or standalone Mac, which decides the show's state and
    /// reports each change here. Nil on a player, which follows (see `follow`).
    private let onStateChange: ((ShowState) -> Void)?
    private var leads: Bool { onStateChange != nil }
    /// [claude] → and ← (P2: one Mac only; across Macs they need P3's state
    /// with a work index, so AppModel turns them off in network modes).
    private let allowSkip: Bool
    private let onWindowsUp: () -> Void
    private let onEnd: () -> Void
    // [claude] Every window this show has opened, tracked from the moment it is
    // built. A stop during loading (Esc, a failed file, a display change)
    // used to leave black windows covering the screens.
    private var windows: [PanelWindow] = []
    private let hostClock = CMClockGetHostTimeClock()
    /// [claude] The timeline's anchor: work `index` starts at show time `start`.
    /// `start` is what ShowState carries as the show's start (v1's h0).
    private var anchor = (index: 0, start: 0.0)
    private var pausedAt: Double?        // show time we paused at, if paused
    private var loaded: LoadedWork?      // the work on screen, or the next one, loaded
    /// [claude] What is being loaded, and a GENERATION number: each new load
    /// takes the next number, and a load that finishes to find the number
    /// moved on (Next was pressed meanwhile) throws its players away instead
    /// of putting a stale work on screen. A cheap way to cancel async work
    /// that can't be interrupted part way.
    private var loading: (index: Int, begins: Double?)?
    private var generation = 0
    private var segmentTimer: Timer?     // fires when the current stretch ends
    private var revealTimer: Timer?      // fires when a loaded work starts
    private var driftTimer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    private var stopped = false
    private var started = false          // true once the first work's start is set
    /// Why the show stopped, if something went wrong; AppModel shows it.
    private(set) var failure: String?

    /// `onWindowsUp` runs once every panel window is on screen; `onEnd` runs
    /// when the show stops, before its windows close.
    ///
    /// [claude] The two callbacks exist to keep one invariant: SOME WINDOW IS
    /// ALWAYS VISIBLE. AppKit treats hiding or closing the last visible window
    /// as "last window closed", and the app is set to quit then. The first
    /// version hid the setup window before the panel windows existed, and the
    /// app quit the moment Play was pressed (confirmed with a diagnostic log on
    /// 2026-10-21). So the hand-over goes: new windows up, then old ones away.
    init(screens: [NSScreen],
         works: [WorkPart],
         playlist: PlaylistSettings,
         sync: SyncSettings,
         clock: ShowClock = .local,
         allowSkip: Bool,
         onStateChange: ((ShowState) -> Void)?,
         onWindowsUp: @escaping () -> Void,
         onEnd: @escaping () -> Void) {
        self.screens = screens
        self.works = works
        self.timeline = Timeline(entries: works.map { .init(length: $0.length, repeat: $0.repeat) }, settings: playlist)
        self.sync = sync
        self.clock = clock
        self.allowSkip = allowSkip
        self.onStateChange = onStateChange
        self.onWindowsUp = onWindowsUp
        self.onEnd = onEnd
    }

    private func hostNow() -> Double { CMClockGetTime(hostClock).seconds }
    private func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1_000_000_000) }
    private func showNow() -> Double? { clock.toShow(hostNow()) }

    // [claude] STAGE LOGGING: one line per step, so a start or a change of
    // work that never happens says where it stopped (and how long each step
    // took), instead of leaving black screens and no clue.
    private func log(_ s: String) { NSLog("playlist: %@", s) }

    private func report(_ phase: ShowState.Phase) {
        onStateChange?(ShowState(version: hostNanos(), phase: phase, start: anchor.start, pausedAt: pausedAt ?? 0))
    }

    /// Starts the show. A leader (conductor, standalone) loads the first
    /// work and starts it 1 s after its panels are ready; a player passes the
    /// conductor's `start` and joins the timeline from it.
    func start(following start: Double? = nil) {
        // Build windows first, so every display goes black at once even while
        // the videos are still loading.
        for screen in screens { windows.append(makeWindow(on: screen)) }
        log("\(windows.count) window(s) up")
        onWindowsUp()
        NSCursor.hide()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "tableauX is playing" as CFString, &sleepAssertion)
        driftTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDrift() }
        }
        if let start {
            anchor = (0, start)
            started = true
            advance()
        } else {
            guard let first = timeline.playable(from: 0) else { log("nothing to play"); stop(); return }
            beginLoad(first, begins: nil)       // nil: "1 s after it's ready"
        }
    }

    // MARK: The timeline [claude]

    /// Puts on screen whatever the timeline says is on now, and sets the
    /// timer for when that changes. Called at the start, at every change,
    /// after a skip and after a resume. Safe to call again at any moment:
    /// if what's loaded is already right, it only re-arms the timer.
    private func advance() {
        segmentTimer?.invalidate()
        guard !stopped, started, pausedAt == nil, let now = showNow() else { return }
        let seg = timeline.segment(at: now, anchor: anchor.index, start: anchor.start)
        let target: (index: Int, begins: Double)
        switch seg.position {
        case .work(let i, _): target = (i, seg.begins)
        case .gap(let n): target = (n, seg.ends!)
        case .waiting:
            guard let k = timeline.playable(from: anchor.index) else { stop(); return }
            target = (k, seg.ends!)
        case .ended:
            log("playlist ended")
            stop()
            return
        }
        if let loaded, loaded.index == target.index, abs(loaded.begins - target.begins) < 1e-6 {
            if !loaded.scheduled { startLoaded() }
        } else if let loading, loading.index == target.index, loading.begins.map({ abs($0 - target.begins) < 1e-6 }) == true {
            // Already on its way.
        } else {
            unload()
            if case .work = seg.position { log("joining \(works[target.index].name) \(String(format: "%.2f", now - target.begins)) s in") }
            beginLoad(target.index, begins: target.begins)
        }
        if let ends = seg.ends { segmentTimer = timer(atShow: ends) { [weak self] in self?.advance() } }
    }

    /// A one-shot timer for a moment in show time. The host time is worked
    /// out now; a player's estimate moves by microseconds a second, far
    /// less than a timer's own jitter.
    private func timer(atShow t: Double, _ f: @escaping @MainActor () -> Void) -> Timer? {
        guard let host = clock.toHost(t) else { return nil }
        let t = Timer(timeInterval: max(0, host - hostNow()), repeats: false) { _ in MainActor.assumeIsolated { f() } }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    /// Builds the players for work `index`, hidden, and prerolls them.
    /// `begins` nil (a leader's first work): start 1 s after they're ready.
    private func beginLoad(_ index: Int, begins: Double?) {
        generation += 1
        let g = generation
        loading = (index, begins)
        let work = works[index]
        let t0 = Date()
        log("loading \(work.name)")
        Task {
            do {
                let panels = try await build(work)
                guard g == generation, !stopped else { teardown(panels); return }
                loading = nil
                guard let now = showNow() else { teardown(panels); return }
                let w = LoadedWork(index: index, begins: begins ?? now + 1, panels: panels)
                observeEnds(w)
                loaded = w
                log(String(format: "%@ ready in %.2f s", work.name, Date().timeIntervalSince(t0)))
                if begins == nil {
                    anchor = (index, w.begins)
                    started = true
                    report(.playing)
                }
                if pausedAt == nil { startLoaded() }
                if begins == nil { advance() }
            } catch {
                guard g == generation else { return }
                loading = nil
                log("couldn't load \(work.name): \(error)")
                // One broken work shouldn't stop a class's playlist; its
                // time passes in black and the next one plays. But with
                // nothing started yet there's no timeline to pass: say so.
                if begins == nil {
                    failure = "Couldn't start \(work.name): \(error.localizedDescription)"
                    stop()
                }
            }
        }
    }

    /// One player per panel, laid out per ItemLayout, layer hidden until the
    /// work starts (a prerolled player shows its first frame, which in the
    /// gap would be a still of the next work, not black).
    private func build(_ work: WorkPart) async throws -> [LivePanel] {
        var built: [LivePanel] = []
        do {
            for (i, window) in windows.enumerated() {
                guard i < work.panels.count, let path = work.panels[i].file, let d = work.durations[path], d > 0 else {
                    built.append(LivePanel(window: window, player: nil, layer: nil, itemDuration: 0, wraps: false, frame: 1.0 / 30, grace: sync.grace))
                    continue
                }
                let config = work.panels[i]
                let pieces = ItemLayout.pieces(fileDuration: d, workLength: work.length, repeat: work.repeat,
                                               shorter: work.shorter, cover: Self.cover, maxPieces: Self.maxSegments)
                let (item, itemDuration, fps) = try await Self.makeItem(URL(fileURLWithPath: path), pieces: pieces)
                let player = AVPlayer(playerItem: item)
                // Needed for setRate(_:time:atHostTime:), which won't schedule a start
                // on a player that's allowed to wait for buffering.
                player.automaticallyWaitsToMinimizeStalling = false
                player.masterClock = hostClock
                player.isMuted = !config.audio
                // At the end of the item, hold still rather than advance; the
                // end is either the work's end or this screen's black (observeEnds).
                player.actionAtItemEnd = .pause
                let layer = attach(player, to: window, scaling: config.scaling)
                built.append(LivePanel(window: window, player: player, layer: layer, itemDuration: itemDuration,
                                       wraps: work.repeat == .untilNext, frame: 1 / max(fps, 1), grace: sync.grace))
            }
            // Wait for every item to be ready, then PREROLL: decode the first frames
            // ahead so the start is only a clock being released, not a cold decode.
            let players = built.compactMap(\.player)
            while let pending = players.first(where: { $0.currentItem?.status != .readyToPlay }) {
                if pending.currentItem?.status == .failed { throw pending.currentItem?.error ?? CocoaError(.fileReadCorruptFile) }
                try await Task.sleep(for: .milliseconds(20))
            }
            for p in players { _ = await p.preroll(atRate: 1) }
            return built
        } catch {
            teardown(built)
            throw error
        }
    }

    /// The file laid out as `pieces` in one composition (see ItemLayout).
    private static func makeItem(_ url: URL, pieces: [ItemLayout.Piece]) async throws -> (AVPlayerItem, Double, Double) {
        let asset = AVURLAsset(url: url)
        let clip = try await asset.load(.duration)
        let fps = Double(try await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate) ?? 30)
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: clip)
        var cursor = CMTime.zero
        for piece in pieces {
            switch piece {
            case .clip:
                try await comp.insertTimeRange(range, of: asset, at: cursor)
                cursor = cursor + clip
            case .empty(let s):
                // On the composition as a whole, so audio goes silent with the picture.
                comp.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: CMTime(seconds: s, preferredTimescale: 1_000_000_000)))
                cursor = cursor + CMTime(seconds: s, preferredTimescale: 1_000_000_000)
            }
        }
        // Carry the file's rotation flag over to the composition's video track,
        // or phone footage shot upright would play sideways.
        if let src = try await asset.loadTracks(withMediaType: .video).first,
           let dst = comp.tracks(withMediaType: .video).first {
            dst.preferredTransform = try await src.load(.preferredTransform)
        }
        return (AVPlayerItem(asset: comp), comp.duration.seconds, fps)
    }

    /// Hides a panel whose item ends before its work does (a shorter file
    /// on "black"): the item stops and would hold its last frame. The end
    /// notification came 3 ms after the end in `proofs/empty-range-probe`.
    private func observeEnds(_ w: LoadedWork) {
        for p in w.panels {
            guard let item = p.player?.currentItem else { continue }
            w.endObservers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
                MainActor.assumeIsolated {
                    guard let p, !p.wraps else { return }
                    p.finished = true
                    p.layer?.isHidden = true
                }
            })
        }
    }

    /// Tells the loaded work's players when to start: at the work's start
    /// if that is far enough ahead, else (loaded late, or joining) at the
    /// position the work will have reached shortly.
    private func startLoaded() {
        guard let w = loaded, let now = showNow() else { return }
        let at = SyncMath.scheduledStart(start: w.begins, now: now)
        guard let host = clock.toHost(at) else { return }
        for p in w.panels {
            guard let player = p.player else { continue }
            let into = at - w.begins
            if !p.wraps && into >= p.itemDuration { p.finished = true; continue }   // already over: stays black
            player.setRate(1, time: cm(expected(p, in: w, atShow: at)), atHostTime: cm(host))
        }
        w.scheduled = true
        log(at == w.begins ? "\(works[w.index].name) starts on time" : String(format: "%@ starts %.2f s in", works[w.index].name, at - w.begins))
        revealTimer?.invalidate()
        revealTimer = timer(atShow: at) { [weak self, weak w] in
            guard let self, let w, self.loaded === w else { return }
            for p in w.panels where !p.finished { p.layer?.isHidden = false }
        }
    }

    /// Takes the loaded work off the screens: black until the next one starts.
    private func unload() {
        revealTimer?.invalidate()
        guard let w = loaded else { return }
        loaded = nil
        w.endObservers.forEach(NotificationCenter.default.removeObserver)
        teardown(w.panels)
    }

    /// Releases a set of players: stop, detach the item, remove the layer.
    /// The same teardown the work-switch probe ran 360 times an hour.
    private func teardown(_ panels: [LivePanel]) {
        for p in panels {
            p.player?.pause()
            p.player?.replaceCurrentItem(with: nil)
            p.layer?.removeFromSuperlayer()
        }
    }

    // MARK: Windows

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

    private func attach(_ player: AVPlayer, to window: PanelWindow, scaling: Scaling) -> AVPlayerLayer? {
        guard let view = window.contentView, let root = view.layer else { return nil }
        let layer = AVPlayerLayer(player: player)
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // ASPECT GRAVITY: uniform scaling, so the image never stretches.
        // resizeAspect = fit (letterbox), resizeAspectFill = fill (crop).
        layer.videoGravity = scaling == .fit ? .resizeAspect : .resizeAspectFill
        // Render at the display's real pixel density, so a 4K screen gets 4K detail.
        layer.contentsScale = window.screen?.backingScaleFactor ?? 2
        layer.backgroundColor = NSColor.black.cgColor
        layer.isHidden = true                     // [claude] until its work starts
        root.addSublayer(layer)
        return layer
    }

    // MARK: Keys

    private func handle(_ e: NSEvent) {
        switch e.keyCode {
        case 53: stop()                                   // Esc
        case 49 where leads: togglePause()                // Space; a player's conductor decides (§ v3 › Show state)
        case 124 where leads && allowSkip: skip(forward: true)    // →
        case 123 where leads && allowSkip: skip(forward: false)   // ←
        default: break
        }
    }

    /// [claude] → / ← (§ v4 › Playing, manual override): black now, the
    /// chosen work after the gap. "Current" is the work playing, or in a gap
    /// the one coming, so → in a gap skips the work about to start.
    private func skip(forward: Bool) {
        guard started, pausedAt == nil, let now = showNow() else { return }
        let seg = timeline.segment(at: now, anchor: anchor.index, start: anchor.start)
        let current: Int
        switch seg.position {
        case .work(let i, _): current = i
        case .gap(let n): current = n
        case .waiting: current = timeline.playable(from: anchor.index) ?? anchor.index
        case .ended: return
        }
        guard let target = forward ? timeline.next(after: current) : timeline.previous(before: current) else { return }
        log("\(forward ? "next" : "previous"): \(works[target].name)")
        anchor = (target, now + timeline.settings.gap)
        unload()
        generation += 1                 // drop any load in flight
        loading = nil
        report(.playing)
        advance()
    }

    private func togglePause() {
        // [claude] Nothing to pause until the start is scheduled. Earlier, a
        // Space while files were still loading paused the players built so far,
        // then start() scheduled them anyway: playing, but marked as paused.
        guard started, let now = showNow() else { return }
        if let paused = pausedAt {
            resume(from: paused, at: now + 0.5)
            report(.playing)
        } else {
            pause(at: now)
            report(.paused)
        }
    }

    private func pause(at t: Double) {
        pausedAt = t
        segmentTimer?.invalidate()
        revealTimer?.invalidate()
        loaded?.panels.forEach { $0.player?.pause() }
        loaded?.scheduled = false
    }

    /// Resume: the whole timeline moves later by however long we were
    /// paused, the loaded work with it, so it carries on from where it was.
    private func resume(from paused: Double, at h1: Double) {
        let newStart = SyncMath.resumedStart(start: anchor.start, pausedAt: paused, resumeAt: h1)
        shift(by: newStart - anchor.start)
        pausedAt = nil
        advance()
    }

    private func shift(by delta: Double) {
        anchor.start += delta
        loaded?.begins += delta
        if loading != nil { generation += 1; loading = nil }    // simpler to reload than to shift a load in flight
    }

    /// [claude] A player brings its playback into line with the conductor's
    /// state (§ v3 › Show state). RECONCILIATION: compare, and change only
    /// what differs, so the once-a-second repeat of an unchanged state does
    /// nothing at all. (Stopped is AppModel's job: it ends the Playback.)
    func follow(_ s: ShowState) {
        guard !leads else { return }
        switch s.phase {
        case .paused:
            guard pausedAt == nil else { return }
            pause(at: s.pausedAt)
            log("follow: paused")
        case .playing:
            // Same start and not paused: already doing this. (1 µs: the start
            // travels as whole nanoseconds.)
            guard pausedAt != nil || abs(s.start - anchor.start) > 1e-6 else { return }
            shift(by: s.start - anchor.start)
            pausedAt = nil
            log("follow: playing")
            advance()
        case .stopped:
            break
        }
    }

    // MARK: Drift

    private func expected(_ p: LivePanel, in w: LoadedWork, atShow t: Double) -> Double {
        p.wraps ? SyncMath.expected(host: t, start: w.begins, duration: p.itemDuration) : t - w.begins
    }

    /// Once a second: is every panel where the shared clock says it should be?
    private func checkDrift() {
        guard pausedAt == nil, let w = loaded, w.scheduled else { return }
        let now = hostNow()
        // [claude] Where the panels should be is a question about SHOW time;
        // where they are is read on the host clock. A player with no clock
        // estimate (none yet) skips the check rather than guess.
        guard let showNow = clock.toShow(now), let h1Show = clock.toShow(now + 0.5) else { return }
        guard showNow >= w.begins else { return }          // not started yet (in the gap)
        for p in w.panels where !p.finished {
            guard let player = p.player, let tb = player.currentItem?.timebase else { continue }
            // Past the end of a work's item: it's ending (or ended); nothing to correct.
            if !p.wraps && expected(p, in: w, atShow: h1Show) >= p.itemDuration { continue }
            // Read the panel's time at exactly `now` by converting that host
            // instant into the panel's own timebase, not by asking "what time is
            // it?" a few microseconds later for each panel in turn.
            let actual = CMSyncConvertTime(cm(now), from: hostClock, to: tb).seconds
            let stalled = player.rate == 0
            let out = SyncMath.needsCorrection(actual: actual, expected: expected(p, in: w, atShow: showNow),
                                               duration: p.itemDuration, frame: p.frame, tolerance: sync.tolerance)
            // A stalled panel is frozen, not drifting: waiting out the grace
            // period would only leave a still picture on screen for longer.
            // The gate is checked first so it sees every check either way.
            if p.gate.check(out: out, now: now) || stalled {
                player.setRate(1, time: cm(expected(p, in: w, atShow: h1Show)), atHostTime: cm(now + 0.5))
                p.corrections += 1
                log("panel resynced (\(stalled ? "stalled" : String(format: "%.1f ms out", abs(actual - expected(p, in: w, atShow: showNow)) * 1000)))")
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        segmentTimer?.invalidate()
        revealTimer?.invalidate()
        driftTimer?.invalidate()
        unload()
        NSApp.presentationOptions = []
        NSCursor.unhide()
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
        // Take the windows into a local first: onEnd() drops AppModel's
        // reference to this Playback, which may free it, so nothing below that
        // call may touch `self`.
        let ours = windows
        windows = []
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
