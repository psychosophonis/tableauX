import XCTest
@testable import PlayerCore

/// [claude] REPLAY TESTS: `ClockEstimator` fed the exchanges the Stage 0a probe
/// recorded between two MacBooks on the university Wi-Fi (2026-10-21, ~9 min,
/// 20 exchanges/s). The synthetic tests in `NetworkClockTests` check the
/// estimator against noise we invented; these check it against noise a real
/// network made, which is the only kind the show will meet.
///
/// What they can't tell, as with the probe: whether the estimate is RIGHT.
/// There is no third clock in the recording, so a steady but wrong estimate
/// passes. Accuracy is target T12's job (sweep-line clips across two Macs).
private let recording = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("clock-probe-1792559249.csv")

/// One recorded exchange plus the probe's own filtered offset for that row
/// (computed by different code, so it can serve as an independent check).
private struct Row { let sample: ClockSample; let probeFilteredMs: Double }

/// Reads the probe's CSV: seq, t1..t4 in ns, round_trip_ms, offset_ms,
/// filtered_offset_ms. Sorted by t4 because `ClockEstimator.add` requires
/// arrival order, and UDP replies can arrive out of sequence.
private func loadRecording() throws -> [Row] {
    let text = try String(contentsOf: recording, encoding: .utf8)
    return text.split(separator: "\n").dropFirst().compactMap { line -> Row? in
        let f = line.split(separator: ",")
        guard f.count == 8, let t1 = Double(f[1]), let t2 = Double(f[2]),
              let t3 = Double(f[3]), let t4 = Double(f[4]), let probe = Double(f[7]) else { return nil }
        return Row(sample: ClockSample(t1: t1 / 1e9, t2: t2 / 1e9, t3: t3 / 1e9, t4: t4 / 1e9),
                   probeFilteredMs: probe)
    }.sorted { $0.sample.t4 < $1.sample.t4 }
}

/// Least-squares line, the same "expected drift trend" the probe measures
/// steadiness against.
private func lineFit(_ x: [Double], _ y: [Double]) -> (slope: Double, intercept: Double) {
    let n = Double(x.count), mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
    let sxy = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
    return (sxy / sxx, my - sxy / sxx * mx)
}

private func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

final class ClockReplayTests: XCTestCase {

    /// T11 on the app's estimator rather than the probe's filter: the offset
    /// the app would act on (conductor time minus host time, read at each
    /// arrival) stays within 5 ms of its drift line for 95% of the run.
    func testRealWiFiEstimateIsSteady() throws {
        let rows = try loadRecording()
        XCTAssertGreaterThan(rows.count, 10_000)
        let start = rows[0].sample.t4
        var clock = ClockEstimator()
        var times: [Double] = [], offsetsMs: [Double] = []
        for row in rows {
            clock.add(row.sample)
            let host = row.sample.t4
            // Skip the first 10 s: the drift fit needs history before the
            // estimate is the one a running show would use.
            guard host - start > 10, let c = clock.conductorTime(host: host) else { continue }
            times.append(host - start)
            offsetsMs.append((c - host) * 1000)
        }
        let fit = lineFit(times, offsetsMs)
        let p95 = percentile(zip(times, offsetsMs).map { abs($1 - (fit.intercept + fit.slope * $0)) }, 0.95)
        print(String(format: "replay: estimator steady to %.3f ms (95%%), drift %.1f ppm", p95, fit.slope * 1000))
        XCTAssertLessThanOrEqual(p95, 5, "T11")
    }

    /// The estimator's drift rate agrees with the slope of the probe's own
    /// filtered offsets. Two separate pieces of code reading the same recording
    /// should find the same clock-rate difference (the probe reported −12 ppm).
    func testDriftMatchesTheProbe() throws {
        let rows = try loadRecording()
        var clock = ClockEstimator()
        rows.forEach { clock.add($0.sample) }
        let start = rows[0].sample.t4
        let probe = lineFit(rows.map { $0.sample.t4 - start }, rows.map(\.probeFilteredMs))
        let probePpm = probe.slope * 1000            // ms per s → ppm
        let ours = try XCTUnwrap(clock.drift) * 1e6
        print(String(format: "replay: drift %.1f ppm (estimator, last 60 s) vs %.1f ppm (probe, whole run)", ours, probePpm))
        XCTAssertEqual(ours, probePpm, accuracy: 2)
    }

    /// A 300 s gap cut out of the real recording (the network gone for five
    /// minutes). Across the gap the estimator runs on extrapolation alone and
    /// must stay within 1 ms of the trend fitted to the whole run.
    ///
    /// Why 300 s and 1 ms: at the measured −12 ppm, an estimator that froze its
    /// last offset would be ~3.6 ms off by the end, so this fails if drift is
    /// ignored. (1 ms is a margin chosen for the test, not a spec target: T13
    /// asks only for no visible desync, i.e. under a frame.)
    func testRealDriftCarriesThroughADropout() throws {
        let rows = try loadRecording()
        let start = rows[0].sample.t4
        let gapStart = start + 120, gapEnd = gapStart + 300
        let whole = lineFit(rows.map { $0.sample.t4 - start }, rows.map(\.probeFilteredMs))

        var clock = ClockEstimator()
        for row in rows where row.sample.t4 < gapStart { clock.add(row.sample) }
        var worstMs = 0.0
        for host in stride(from: gapStart, to: gapEnd, by: 1) {
            let c = try XCTUnwrap(clock.conductorTime(host: host))
            let trend = whole.intercept + whole.slope * (host - start)
            worstMs = max(worstMs, abs((c - host) * 1000 - trend))
        }
        print(String(format: "replay: worst error across a 300 s dropout %.3f ms", worstMs))
        XCTAssertLessThan(worstMs, 1)
    }
}
