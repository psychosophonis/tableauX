import XCTest
@testable import PlayerCore

/// Builds the exchange a real network would produce, from the TRUE values:
/// the conductor's clock is `offset` ahead of the player's, the trip out takes
/// `out` seconds, the conductor holds the packet `hold` seconds, the trip back
/// takes `back` seconds.
private func exchange(at t1: Double, offset: Double, out: Double, back: Double, hold: Double = 0.0001) -> ClockSample {
    let t2 = t1 + out + offset
    let t3 = t2 + hold
    let t4 = t3 - offset + back
    return ClockSample(t1: t1, t2: t2, t3: t3, t4: t4)
}

/// A seeded random generator, so the noise tests give the same numbers on
/// every run: a test that passes only sometimes teaches nothing.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {           // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class NetworkClockTests: XCTestCase {

    func testSymmetricTripGivesTheExactOffset() {
        let s = exchange(at: 100, offset: 0.0075, out: 0.004, back: 0.004)
        XCTAssertEqual(s.offset, 0.0075, accuracy: 1e-12)
        XCTAssertEqual(s.roundTrip, 0.008, accuracy: 1e-12)
    }

    func testOneSidedDelayBiasesTheOffsetByHalfTheDifference() {
        // 20 ms extra on the way back: the raw offset is wrong by 10 ms.
        // This is the error the min-RTT filter exists to avoid.
        let s = exchange(at: 100, offset: 0.0075, out: 0.002, back: 0.022)
        XCTAssertEqual(s.offset, 0.0075 - 0.010, accuracy: 1e-12)
    }

    func testFilterTrustsTheFastestExchange() {
        var c = ClockEstimator()
        c.add(exchange(at: 100.0, offset: 0.0075, out: 0.002, back: 0.030))
        c.add(exchange(at: 100.1, offset: 0.0075, out: 0.002, back: 0.002))   // fast and fair
        c.add(exchange(at: 100.2, offset: 0.0075, out: 0.002, back: 0.040))
        XCTAssertEqual(c.filtered?.offset ?? .nan, 0.0075, accuracy: 1e-9)
    }

    func testOldExchangesLeaveTheWindow() {
        var c = ClockEstimator(window: 2)
        c.add(exchange(at: 100, offset: 0.001, out: 0.001, back: 0.001))     // fast, but will expire
        c.add(exchange(at: 103, offset: 0.002, out: 0.005, back: 0.005))
        XCTAssertEqual(c.filtered?.offset ?? .nan, 0.002, accuracy: 1e-9)
    }

    func testDriftIsRecoveredAndUsedToExtrapolate() {
        // Conductor clock runs 50 ppm fast; exchanges at 20/s for 30 s.
        var c = ClockEstimator()
        let ppm = 50e-6
        for i in 0..<600 {
            let t = 1000 + Double(i) * 0.05
            c.add(exchange(at: t, offset: 0.0075 + ppm * (t - 1000), out: 0.003, back: 0.003))
        }
        XCTAssertEqual(c.drift ?? .nan, ppm, accuracy: 1e-7)
        // 60 s after the last exchange (a dropout), the extrapolation still holds.
        let host: Double = 1090
        let truth: Double = host + 0.0075 + ppm * 90
        XCTAssertEqual(c.conductorTime(host: host) ?? .nan, truth, accuracy: 1e-4)
    }

    func testNoEstimateBeforeAnyExchange() {
        XCTAssertNil(ClockEstimator().conductorTime(host: 5))
        XCTAssertNil(ClockEstimator().drift)
    }

    /// The probe's control A, made deterministic: 0–20 ms of noise added to
    /// the way back only, 20 exchanges/s, 40 s. The filtered estimate must stay
    /// within 1 ms of the truth throughout (the probe measured 0.2–0.4 ms).
    func testOneSidedNoiseIsFilteredOut() {
        var rng = SeededRandom(state: 42)
        var c = ClockEstimator()
        var worst = 0.0
        for i in 0..<800 {
            let t = 2000 + Double(i) * 0.05
            c.add(exchange(at: t, offset: 0.0075, out: 0.002,
                           back: 0.002 + Double.random(in: 0...0.020, using: &rng)))
            if i > 40 { worst = max(worst, abs((c.filtered?.offset ?? .nan) - 0.0075)) }
        }
        XCTAssertLessThan(worst, 0.001)
    }

    // MARK: correction rule

    func testSignedErrorTakesTheShortWayRoundAndKeepsDirection() {
        XCTAssertEqual(SyncMath.signedError(actual: 5.02, expected: 5.0, duration: 60), 0.02, accuracy: 1e-9)
        XCTAssertEqual(SyncMath.signedError(actual: 4.98, expected: 5.0, duration: 60), -0.02, accuracy: 1e-9)
        // Just past the wrap is slightly ahead, not 59.99 s behind.
        XCTAssertEqual(SyncMath.signedError(actual: 0.005, expected: 59.995, duration: 60), 0.01, accuracy: 1e-9)
    }

    func testCorrectionBands() {
        let frame = 1.0 / 30
        XCTAssertEqual(SyncMath.correction(error: 0.005, frame: frame), .none)        // under ¼ frame
        XCTAssertEqual(SyncMath.correction(error: 0.040, frame: frame), .resync)      // over a frame
        XCTAssertEqual(SyncMath.correction(error: -0.040, frame: frame), .resync)
    }

    func testSlewPushesTheRightWayAndIsCapped() {
        let frame = 1.0 / 30
        // 10 ms ahead: slow down by 10 ms / 2 s = 0.5%.
        XCTAssertEqual(SyncMath.correction(error: 0.010, frame: frame), .slew(rate: 0.995))
        // 10 ms behind: speed up.
        XCTAssertEqual(SyncMath.correction(error: -0.010, frame: frame), .slew(rate: 1.005))
        // 30 ms ahead would need 1.5%: capped at 0.5%.
        XCTAssertEqual(SyncMath.correction(error: 0.030, frame: frame), .slew(rate: 0.995))
    }

    // MARK: Stage 2 [claude]

    func testPacketRoundTrips() {
        let p = ClockPacket(seq: 42, t1: 7_212_965_987_791, t2: 773_111_958_167_500, t3: .max)
        XCTAssertEqual(p.bytes.count, 32)
        XCTAssertEqual(ClockPacket(bytes: p.bytes), p)
    }

    /// The app's bytes are the probe's bytes: the probe sends a native [UInt64]
    /// array, and every Mac is little-endian. This is what lets the probe test
    /// the app (and the app the probe).
    func testPacketMatchesTheProbesLayout() {
        let words: [UInt64] = [1, 0x0102_0304_0506_0708, 3, 4]
        let native = words.withUnsafeBytes { Array($0) }
        XCTAssertEqual(ClockPacket(seq: 1, t1: 0x0102_0304_0506_0708, t2: 3, t3: 4).bytes, native)
    }

    func testWrongSizedDatagramIsNotAPacket() {
        XCTAssertNil(ClockPacket(bytes: [UInt8](repeating: 0, count: 31)))
        XCTAssertNil(ClockPacket(bytes: [UInt8](repeating: 0, count: 33)))
    }

    func testPacketBecomesASampleInSeconds() {
        let s = ClockPacket(seq: 0, t1: 1_000_000_000, t2: 6_000_000_000, t3: 6_000_100_000).sample(t4: 1_010_100_000)
        XCTAssertEqual(s.offset, 4.995, accuracy: 1e-9)          // ((6 − 1) + (6.0001 − 1.0101)) / 2
        XCTAssertEqual(s.roundTrip, 0.01, accuracy: 1e-9)
    }

    /// Drift is not wobble: an offset moving in a perfectly straight line
    /// (here 50 ppm) must read as perfectly steady.
    func testSteadyDriftReadsAsSteady() {
        var m = SteadinessMeter()
        for i in 0..<600 { let t = Double(i) * 0.05; m.add(time: t, offset: 0.0075 + 50e-6 * t) }
        XCTAssertEqual(try XCTUnwrap(m.p95Spread), 0, accuracy: 1e-9)
    }

    func testKnownScatterGivesKnownSpread() {
        var m = SteadinessMeter()
        // ±1 ms around a drifting line, alternating: every point is 1 ms out.
        for i in 0..<600 { let t = Double(i) * 0.05; m.add(time: t, offset: 50e-6 * t + (i % 2 == 0 ? 0.001 : -0.001)) }
        XCTAssertEqual(try XCTUnwrap(m.p95Spread), 0.001, accuracy: 1e-5)
    }

    func testOldWobbleLeavesTheWindow() {
        var m = SteadinessMeter(window: 60)
        for i in 0..<100 { m.add(time: Double(i) * 0.1, offset: i % 2 == 0 ? 0.01 : -0.01) }   // 10 s of 10 ms wobble
        for i in 0..<700 { m.add(time: 10 + Double(i) * 0.1, offset: 0) }                     // then 70 s still
        XCTAssertEqual(try XCTUnwrap(m.p95Spread), 0, accuracy: 1e-9)
    }

    // MARK: Stage 3a [claude]

    func testShowStateRoundTrips() {
        for s in [ShowState(version: 9, phase: .playing, start: 773_112.5, pausedAt: 0),
                  ShowState(version: 10, phase: .paused, start: 773_112.5, pausedAt: 773_140.25),
                  ShowState(version: 11, phase: .stopped)] {
            let back = ShowState(bytes: s.bytes)
            XCTAssertEqual(s.bytes.count, 40)
            XCTAssertEqual(back?.phase, s.phase)
            XCTAssertEqual(back?.version, s.version)
            XCTAssertEqual(try XCTUnwrap(back?.start), s.start, accuracy: 1e-9)       // ns precision
            XCTAssertEqual(try XCTUnwrap(back?.pausedAt), s.pausedAt, accuracy: 1e-9)
        }
    }

    /// A clock packet can never be read as a state (different size), and 40
    /// bytes without the magic word, or with an unknown phase, aren't ours.
    func testOnlyRealStatesAreRead() {
        XCTAssertNil(ShowState(bytes: ClockPacket(seq: 1, t1: 2).bytes))
        XCTAssertNil(ShowState(bytes: [UInt8](repeating: 0, count: 40)))
        var bad = ShowState(version: 1, phase: .playing).bytes
        bad[16] = 7                                                              // phase word = 7
        XCTAssertNil(ShowState(bytes: bad))
    }

    func testFollowerIgnoresAnOlderStateThatArrivesLate() {
        var f = StateFollower()
        XCTAssertTrue(f.accept(ShowState(version: 2, phase: .playing), now: 100))
        XCTAssertFalse(f.accept(ShowState(version: 1, phase: .paused), now: 100.2))   // reordered
        XCTAssertEqual(f.current?.phase, .playing)
        XCTAssertTrue(f.accept(ShowState(version: 2, phase: .playing), now: 101))     // the repeat
        XCTAssertTrue(f.accept(ShowState(version: 3, phase: .paused), now: 102))
    }

    func testFollowerAcceptsARestartedConductorAfterTheTakeover() {
        var f = StateFollower()
        XCTAssertTrue(f.accept(ShowState(version: 900, phase: .playing), now: 100))
        XCTAssertFalse(f.accept(ShowState(version: 5, phase: .stopped), now: 104.9))
        XCTAssertTrue(f.accept(ShowState(version: 5, phase: .stopped), now: 105.1))
    }

    func testNoSpreadFromTooFewPoints() {
        var m = SteadinessMeter()
        for i in 0..<9 { m.add(time: Double(i), offset: 0) }
        XCTAssertNil(m.p95Spread)
    }
}
