import Foundation

/// The arithmetic behind keeping panels in step. All times are seconds.
///
/// The model: every panel shares one start instant `start` on the HOST CLOCK
/// (the Mac's monotonic system clock, which never jumps when the wall-clock time
/// changes). A panel is in sync when its item time equals the time elapsed since
/// `start`, wrapped to the item's length. Each panel is checked against that
/// shared reference rather than against another panel. That's a
/// REFERENCE-CLOCK design (one clock, many followers), not peer-to-peer
/// comparison, so one late panel can't drag the others with it.
public enum SyncMath {

    /// Where a panel's item should be at `host`: (host − start) wrapped to `duration`.
    ///
    /// The wrap is a MODULO on a circle: an item of length 60 s at elapsed 61 s
    /// should be at 1 s. Swift's `truncatingRemainder` keeps the sign of the
    /// dividend, so a negative elapsed time (asking about an instant before the
    /// start) would come out negative. We add one duration and wrap again to land
    /// in [0, duration).
    public static func expected(host: Double, start: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let r = (host - start).truncatingRemainder(dividingBy: duration)
        return r < 0 ? r + duration : r
    }

    /// The gap between two positions on a loop of length `duration`, taking the
    /// shorter way round.
    ///
    /// This is CIRCULAR DISTANCE. Item time wraps, so 0.01 s and 59.99 s on a
    /// 60 s loop are 0.02 s apart, not 59.98 s. A plain subtraction would see a
    /// huge error at every wrap and trigger a pointless correction.
    public static func circularDistance(_ a: Double, _ b: Double, duration: Double) -> Double {
        guard duration > 0 else { return abs(a - b) }
        let d = abs(a - b).truncatingRemainder(dividingBy: duration)
        return min(d, duration - d)
    }

    /// Whether a panel is far enough out to be pulled back.
    ///
    /// The threshold is `tolerance` frames, at least one. Below one frame, a
    /// correction can't make the picture better: the panel is already showing
    /// the right frame, and the seek a correction needs would itself cause a
    /// visible hitch. This is a DEADBAND: a zone of tolerated error where the
    /// controller does nothing, so tiny measurement noise doesn't trigger a
    /// stream of corrections. [claude] A show can widen it (`SyncSettings`),
    /// trading closeness for fewer jumps.
    public static func needsCorrection(actual: Double, expected: Double, duration: Double,
                                       frame: Double, tolerance: Int = 1) -> Bool {
        circularDistance(actual, expected, duration: duration) > frame * Double(max(tolerance, 1))
    }

    /// How far `actual` is AHEAD of `expected` on a loop (negative = behind),
    /// taking the shorter way round, in (−duration/2, duration/2].
    ///
    /// The signed partner of `circularDistance`: a speed correction needs to
    /// know which way to push, not just how far.
    public static func signedError(actual: Double, expected: Double, duration: Double) -> Double {
        guard duration > 0 else { return actual - expected }
        var d = (actual - expected).truncatingRemainder(dividingBy: duration)
        if d > duration / 2 { d -= duration }
        if d <= -duration / 2 { d += duration }
        return d
    }

    /// What to do about a panel that is `error` seconds ahead (negative =
    /// behind) of where its clock says it should be.
    public enum Correction: Equatable {
        case none
        /// Play at this rate (just off 1.0) until the next check.
        case slew(rate: Double)
        /// Jump to the right time, as v1 does.
        case resync
    }

    /// [claude] The v3 correction rule (docs/architecture.md, v3 § Clock).
    ///
    /// Three bands, a GRADED CONTROLLER rather than v1's single deadband:
    /// - under a quarter frame: leave it alone. Clock estimates jitter by
    ///   around a millisecond, and chasing that would make the rate hunt.
    /// - up to one frame: SLEW, i.e. play slightly fast or slow so the error
    ///   melts away over `horizon` seconds. A 0.5% speed change is invisible
    ///   (and, with a pitch-keeping audio algorithm, inaudible), while a seek
    ///   is a visible hitch. This is how MultiScreener kept machines together.
    ///   The rate is capped at ±`maxRateChange`, so a bigger error just takes
    ///   longer to close.
    /// - over one frame: RESYNC with a seek, exactly as v1's drift check does,
    ///   so target T3 is unchanged. Slewing only adds the sub-frame band.
    public static func correction(error: Double, frame: Double,
                                  horizon: Double = 2, maxRateChange: Double = 0.005) -> Correction {
        let size = abs(error)
        if size > frame { return .resync }
        if size < frame / 4 { return .none }
        // Ahead (error > 0) means slow down: rate below 1.
        let change = min(maxRateChange, size / horizon)
        return .slew(rate: error > 0 ? 1 - change : 1 + change)
    }

    /// The shared start after a pause, so playback resumes where it stopped.
    ///
    /// Pausing freezes the picture but not the host clock, so the reference
    /// start has to move forward by the length of the pause: resuming at
    /// `resumeAt` must show what was on screen at `pausedAt`. That's a SHIFT OF
    /// ORIGIN: rather than tracking "time spent paused" as extra state, the
    /// pause is folded into `start`, and `expected` needs no change.
    ///
    /// [claude] The pause time is clamped to the start. Pausing in the second
    /// between pressing Play and the scheduled start used to give a pause
    /// "before the beginning", a negative elapsed time, which `expected` wrapped
    /// to the END of the 24-hour item: playback resumed near its end and froze
    /// there. Clamped, a pause before the start resumes from frame 0.
    public static func resumedStart(start: Double, pausedAt: Double, resumeAt: Double) -> Double {
        start + resumeAt - max(pausedAt, start)
    }

    /// [claude] When to start a panel that should be playing from `start`
    /// (§ v3 › Show state › Starting late). All times in show time.
    ///
    /// If the start is still at least `minLead` ahead, start exactly at it,
    /// from frame 0: v1's scheduled start. If it is closer than that or has
    /// passed (a player whose files took longer to load, or that joined
    /// late), start `lead` from now instead, at whatever position the show has
    /// reached by then (`expected(host: returned, start:, duration:)`). A
    /// panel that is late then JOINS IN SYNC rather than starting from the
    /// beginning, which would put it a whole load-time behind for the rest of
    /// the show.
    public static func scheduledStart(start: Double, now: Double, minLead: Double = 0.1, lead: Double = 0.5) -> Double {
        start - now >= minLead ? start : now + lead
    }

    /// How many back-to-back copies of a clip to put in one item.
    ///
    /// Enough to cover `cover` seconds, but never more than `maxSegments`, and
    /// at least 1. The cap is there because each copy is a segment in the
    /// composition, and very large segment counts slow the build and use memory.
    /// When a capped item runs out, the drift check notices the stopped panel
    /// and restarts it on the shared clock, so a cap costs one brief resync per
    /// pass rather than a break in sync.
    public static func repeats(duration: Double, cover: Double, maxSegments: Int) -> Int {
        guard duration > 0 else { return 1 }
        return max(1, min(maxSegments, Int((cover / duration).rounded(.up))))
    }
}

/// [claude] The grace period of the drift check (docs/architecture.md § Sync):
/// a panel must be out of tolerance at every check for `grace` seconds before
/// it is re-synced.
///
/// This is a DEBOUNCE: a condition has to persist before it is acted on, so a
/// passing error (a network blip, a momentary stall in reading the clock)
/// doesn't cost a visible seek. Any check that finds the panel back in
/// tolerance starts the wait again, and so does a resync, so a panel that stays
/// out is corrected at most once per grace period, not once per check.
/// `grace: 0` is no debounce at all: v1's correct-at-once rule.
public struct DriftGate {
    public let grace: Double
    private var outSince: Double?        // host time of the first check that found it out

    public init(grace: Double) { self.grace = grace }

    /// Call once per drift check. Returns true when the panel should be
    /// re-synced now.
    public mutating func check(out: Bool, now: Double) -> Bool {
        guard out else { outSince = nil; return false }
        let since = outSince ?? now
        guard now - since >= grace else { outSince = since; return false }
        outSince = nil
        return true
    }
}
