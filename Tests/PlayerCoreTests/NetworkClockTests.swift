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
}
