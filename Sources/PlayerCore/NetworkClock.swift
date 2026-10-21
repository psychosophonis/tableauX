import Foundation

/// One timestamp exchange with the conductor. All times are seconds.
///
/// The player sends at `t1` (its clock); the conductor receives at `t2` and
/// replies at `t3` (the conductor's clock); the reply arrives at `t4` (the
/// player's clock). This is the exchange NTP has used since the 1980s.
public struct ClockSample: Equatable {
    public let t1, t2, t3, t4: Double

    public init(t1: Double, t2: Double, t3: Double, t4: Double) {
        self.t1 = t1; self.t2 = t2; self.t3 = t3; self.t4 = t4
    }

    /// Time spent on the network: the whole round trip, minus the time the
    /// conductor held the packet.
    public var roundTrip: Double { (t4 - t1) - (t3 - t2) }

    /// Conductor clock minus player clock.
    ///
    /// Exact only if the trip out and the trip back took equally long. Any
    /// difference between them shows up as error of half that difference,
    /// which is why `ClockEstimator` trusts only the fastest exchanges.
    public var offset: Double { ((t2 - t1) + (t3 - t4)) / 2 }
}

/// The player's running estimate of the conductor's clock (v3 § Clock).
///
/// Two ideas, each answering a different kind of error:
///
/// 1. MIN-RTT FILTERING, for network noise. Queueing on Wi-Fi only ever ADDS
///    delay, and usually to one direction more than the other, which biases a
///    sample's offset. The fastest round trip in a recent window is the one
///    with the least room for that bias, so the estimate uses its offset and
///    ignores the rest. (Cristian's algorithm, as NTP filters.)
///    Measured by proofs/clock-probe.swift with 0–50 ms of one-sided noise at
///    20 samples/s: raw samples scattered 12.8 ms, the filtered estimate
///    1.1 ms. At 2 samples/s the filter had too little to choose from and
///    failed (11.7 ms), so the sample rate matters.
///
/// 2. A DRIFT RATE, for the clocks running at different speeds. Two Macs'
///    crystals differ by parts per million, so the true offset moves slowly
///    and steadily. A straight-line fit through the recent filtered estimates
///    gives that rate, so the offset can be extrapolated between samples and
///    through a network dropout instead of being frozen at its last value.
public struct ClockEstimator {
    /// How far back the min-RTT filter looks, in seconds.
    public let window: Double
    /// How far back the drift fit looks, in seconds. Longer is smoother;
    /// drift changes slowly (with temperature), so a minute is plenty.
    public let trendWindow: Double

    private var recent: [ClockSample] = []
    private var trend: [(time: Double, offset: Double)] = []

    public init(window: Double = 2, trendWindow: Double = 60) {
        self.window = window; self.trendWindow = trendWindow
    }

    /// Adds an exchange. Samples must arrive in order of `t4`.
    public mutating func add(_ s: ClockSample) {
        recent.append(s)
        recent.removeAll { s.t4 - $0.t4 > window }
        // Each trusted sample enters the drift history once, at the moment its
        // offset was true (the middle of its exchange). Recording the same
        // sample again at every later time would smear its offset forward in
        // time and bias the slope.
        if let best = filtered, best != lastTrended {
            trend.append(((best.t1 + best.t4) / 2, best.offset))
            lastTrended = best
        }
        trend.removeAll { s.t4 - $0.time > trendWindow }
    }

    private var lastTrended: ClockSample?

    /// The fastest exchange in the window, the one the estimate trusts.
    public var filtered: ClockSample? { recent.min { $0.roundTrip < $1.roundTrip } }

    /// Conductor clock minus player clock, per second of player time
    /// (e.g. 50e-6 = 50 ppm). Nil until the history spans a few seconds.
    public var drift: Double? {
        guard let first = trend.first, let last = trend.last, last.time - first.time >= 5 else { return nil }
        let n = Double(trend.count)
        let mx = trend.reduce(0) { $0 + $1.time } / n
        let my = trend.reduce(0) { $0 + $1.offset } / n
        let sxy = trend.reduce(0) { $0 + ($1.time - mx) * ($1.offset - my) }
        let sxx = trend.reduce(0) { $0 + ($1.time - mx) * ($1.time - mx) }
        return sxx > 0 ? sxy / sxx : nil
    }

    /// The conductor's time at player host time `host`, or nil before the
    /// first exchange. Extrapolates from the trusted sample by the drift rate.
    public func conductorTime(host: Double) -> Double? {
        guard let best = filtered else { return nil }
        let midpoint = (best.t1 + best.t4) / 2      // when that offset was true
        return host + best.offset + (drift ?? 0) * (host - midpoint)
    }
}

/// [claude] One clock request or reply on the wire (v3 § Clock › Wire): four
/// UInt64s, sequence number then t1, t2, t3 in nanoseconds.
///
/// The byte order is fixed as LITTLE-ENDIAN rather than left to the machine.
/// Every Mac this runs on happens to be little-endian, so "native" would work
/// today, but a wire format is a CONTRACT between two programs, and a
/// contract shouldn't depend on an accident of the hardware. Fixing it costs
/// nothing and makes the probe's packets and the app's interchangeable.
public struct ClockPacket: Equatable {
    public static let size = 32
    public var seq, t1, t2, t3: UInt64

    public init(seq: UInt64, t1: UInt64, t2: UInt64 = 0, t3: UInt64 = 0) {
        self.seq = seq; self.t1 = t1; self.t2 = t2; self.t3 = t3
    }

    public var bytes: [UInt8] {
        [seq, t1, t2, t3].flatMap { v in (0..<8).map { UInt8(truncatingIfNeeded: v.littleEndian >> ($0 * 8)) } }
    }

    /// Nil unless exactly `size` bytes: a short or long datagram is not ours.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.size else { return nil }
        func word(_ i: Int) -> UInt64 {
            (0..<8).reduce(0) { $0 | UInt64(bytes[i * 8 + $1]) << ($1 * 8) }
        }
        self.init(seq: word(0), t1: word(1), t2: word(2), t3: word(3))
    }

    /// The finished exchange, in seconds, once the reply arrives at `t4` ns.
    public func sample(t4: UInt64) -> ClockSample {
        ClockSample(t1: Double(t1) / 1e9, t2: Double(t2) / 1e9, t3: Double(t3) / 1e9, t4: Double(t4) / 1e9)
    }
}

/// [claude] T11's measure, kept live: how far the offset estimate wanders from
/// its own drift trend, as the 95th percentile over the last `window` seconds.
///
/// Measuring spread AROUND A FITTED LINE, not around the mean, is the point:
/// two clocks drift apart steadily (−12 ppm on Mat's MacBooks), so the offset
/// is supposed to move. The mean would count that steady movement as
/// unsteadiness; the residuals from a line count only the wandering. This is
/// the same measure the probe prints, so the app's number and the probe's
/// can be compared directly.
public struct SteadinessMeter {
    public let window: Double
    private var points: [(time: Double, offset: Double)] = []

    public init(window: Double = 60) { self.window = window }

    /// Times in order, seconds; offsets in seconds.
    public mutating func add(time: Double, offset: Double) {
        points.append((time, offset))
        points.removeAll { time - $0.time > window }
    }

    /// The 95th-percentile distance from the trend, in seconds; nil with too
    /// few points to fit a line meaningfully.
    public var p95Spread: Double? {
        guard points.count >= 10 else { return nil }
        let n = Double(points.count)
        let mx = points.reduce(0) { $0 + $1.time } / n
        let my = points.reduce(0) { $0 + $1.offset } / n
        let sxy = points.reduce(0) { $0 + ($1.time - mx) * ($1.offset - my) }
        let sxx = points.reduce(0) { $0 + ($1.time - mx) * ($1.time - mx) }
        let slope = sxx > 0 ? sxy / sxx : 0
        let spread = points.map { abs($0.offset - (my + slope * ($0.time - mx))) }.sorted()
        return spread[min(spread.count - 1, Int(Double(spread.count - 1) * 0.95))]
    }
}
