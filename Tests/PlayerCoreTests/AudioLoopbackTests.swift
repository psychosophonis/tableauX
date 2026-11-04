import AVFoundation
import CoreAudio
import XCTest
@testable import PlayerCore

/// [claude] v5: a real bake played by AVPlayer with Playback's settings (one play,
/// no repeats and no video), with what ARRIVED at the device's inputs measured
/// (docs/architecture.md § Targets).
///
/// It needs a device whose outputs come back in, so it is skipped unless named:
///
///     TABLEAUX_LOOPBACK_DEVICE="Audio Bridge 16" swift test --filter AudioLoopback
///
/// On a virtual device this shows T19 and T20: the right channels, sample-aligned.
/// It can't show T23: the one tried here (Pro Tools Audio Bridge 16) read 0.00 ppm
/// against the host clock, so there is no drift for it to reveal. For T23, name the real interface, cable an output to the input of the same
/// number, and run it long:
///
///     TABLEAUX_LOOPBACK_DEVICE="UMC" TABLEAUX_LOOPBACK_OUTPUTS=1 \
///     TABLEAUX_LOOPBACK_SECONDS=1800 swift test --filter AudioLoopback
///
/// Keep the Mac awake for a long run, with the lid open and the command prefixed
/// `caffeinate -i` (closing the lid sleeps the Mac regardless). The test compares
/// arrival times with the HOST CLOCK, and that clock, `CLOCK_UPTIME_RAW`, stops while
/// the Mac sleeps: on the Mac that wrote this it read about 72 hours behind a clock
/// that counts sleep. So a nap wouldn't show up as lateness, only as a gap in the
/// clicks, and a clock that can stop is why a long run needs staying awake.
final class AudioLoopbackTests: XCTestCase {
    private func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }

    private func address(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func string(_ d: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
        var a = address(s), v: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr, let v else { return "" }
        return v.takeRetainedValue() as String
    }

    private func device(named part: String) -> (AudioObjectID, String)? {
        var a = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids)
        return ids.first { string($0, kAudioObjectPropertyName).contains(part) }.map { ($0, string($0, kAudioDevicePropertyDeviceUID)) }
    }

    /// What the input side heard. Only click times and a few seconds of each
    /// channel are kept: a long run at many channels would otherwise hold gigabytes.
    private final class Capture {
        static let keep = 240_000
        var opening: [[Float]] = []
        var peaks: [Float] = []
        var clicks: [[(index: Int, host: Double)]] = []
        var seen = 0
        var quietUntil: [Int] = []
    }

    func testABakePlaysOnItsOutputsInStepAndOnTime() async throws {
        guard let name = env("TABLEAUX_LOOPBACK_DEVICE") else { throw XCTSkip("Set TABLEAUX_LOOPBACK_DEVICE: see the header.") }
        let (dev, uid) = try XCTUnwrap(device(named: name), "no device matching \(name)")
        let outputs = (env("TABLEAUX_LOOPBACK_OUTPUTS") ?? "1,2,5,9").split(separator: ",").compactMap { Int($0) }
        let seconds = Int(env("TABLEAUX_LOOPBACK_SECONDS") ?? "10") ?? 10
        let rate = 48000.0
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // One mono file per output: its own tone, a click on every whole second.
        let tones = outputs.indices.map { 300.0 * Double($0 + 1) }
        var sources: [URL] = []
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        for (i, hz) in tones.enumerated() {
            let url = dir.appendingPathComponent("s\(i).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let block = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
            block.frameLength = block.frameCapacity
            for n in 0..<Int(rate) { block.floatChannelData![0][n] = n == 0 ? 0.9 : Float(0.1 * sin(2 * .pi * hz * Double(n) / rate)) }
            for _ in 0..<seconds { try file.write(from: block) }
            sources.append(url)
        }

        var facts: [AudioFacts?] = []
        for s in sources { facts.append(try await AudioBake.analyse(s)) }
        let routes = outputs.enumerated().map { AudioRoute(file: "s\($0.offset)", output: $0.element) }
        let plan = AudioRouting.plan(routes: routes, facts: facts)
        let baked = dir.appendingPathComponent("baked.wav")
        try await AudioBake.bake(plan: plan, sources: sources, to: baked)

        // As Playback.build does it: one play laid out in a composition, on the
        // host clock, started at a scheduled host time, on the named device.
        let asset = AVURLAsset(url: baked)
        let composition = AVMutableComposition()
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: asset, at: .zero)
        let item = await AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        player.audioOutputDeviceUniqueID = uid
        player.automaticallyWaitsToMinimizeStalling = false
        player.masterClock = CMClockGetHostTimeClock()
        while player.currentItem?.status != .readyToPlay { try await Task.sleep(for: .milliseconds(20)) }
        _ = await player.preroll(atRate: 1)

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let toSeconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let capture = Capture()
        let queue = DispatchQueue(label: "loopback")
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, queue) { _, input, time, _, _ in
            let host = Double(time.pointee.mHostTime) * toSeconds
            var c = 0, count = 0
            for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                let nc = Int(b.mNumberChannels)
                guard nc > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                count = Int(b.mDataByteSize) / 4 / nc
                for k in 0..<nc {
                    if capture.opening.count <= c {
                        capture.opening.append([]); capture.peaks.append(0); capture.clicks.append([]); capture.quietUntil.append(0)
                    }
                    for i in 0..<count {
                        let v = abs(d[i * nc + k])
                        capture.peaks[c] = max(capture.peaks[c], v)
                        let at = capture.seen + i
                        if v > 0.6, at >= capture.quietUntil[c] {
                            capture.clicks[c].append((at, host + Double(i) / rate))
                            capture.quietUntil[c] = at + Int(rate) / 2
                        }
                        if capture.opening[c].count < Capture.keep { capture.opening[c].append(d[i * nc + k]) }
                    }
                    c += 1
                }
            }
            capture.seen += count
        }
        XCTAssertEqual(status, noErr)
        let id = try XCTUnwrap(proc)
        AudioDeviceStart(dev, id)
        try await Task.sleep(for: .milliseconds(200))
        let h0 = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 1
        player.setRate(1, time: .zero, atHostTime: CMTime(seconds: h0, preferredTimescale: 1_000_000_000))
        try await Task.sleep(for: .seconds(Double(seconds) + 2))
        player.pause()
        AudioDeviceStop(dev, id)
        AudioDeviceDestroyIOProcID(dev, id)

        let (clicks, opening, peaks) = queue.sync { (capture.clicks, capture.opening, capture.peaks) }
        var firsts: [Int] = []
        for (i, output) in outputs.enumerated() {
            let c = output - 1
            XCTAssertLessThan(c, clicks.count, "the device has no input \(output)")
            guard c < clicks.count else { continue }
            XCTAssertEqual(clicks[c].count, seconds, "output \(output): a click per second")
            firsts.append(clicks[c].first?.index ?? -1)
            // T19: this channel carries its own tone and nobody else's.
            let levels = tones.map { Self.level(opening[c], hz: $0, rate: rate) }
            let others = levels.enumerated().filter { $0.offset != i }.map(\.element).max() ?? 0
            print(String(format: "output %2d: own tone %.4f, loudest other %.6f (%.0f dB)", output, levels[i], others, 20 * log10(max(others, 1e-9) / levels[i])))
            XCTAssertLessThan(others, levels[i] * 0.001, "T19: output \(output) crosstalk under −60 dB")

            // T23's measure: where each click arrived against where it should.
            //
            // Only the SLOPE of that lateness matters. The first click's lateness is
            // a fixed latency through the device and cable, which doesn't change.
            // The slope, in ppm (microseconds gained per second), says whether sound
            // is walking away from the host clock, and so from the picture. Near 0
            // on a real interface: AVPlayer is correcting for the device's crystal.
            // Near that device's own rate (proofs/audio-clock-probe.swift measures
            // it): it isn't, and long loops need a re-sync.
            // A slope of exactly 0 on a virtual device means nothing either way.
            let late = clicks[c].enumerated().map { (k, click) in click.host - (h0 + Double(k)) }
            if let a = late.first, let b = late.last {
                let span = Double(max(late.count - 1, 1))
                let spacings = Set(zip(clicks[c].dropFirst(), clicks[c]).map { $0.index - $1.index })
                print(String(format: "output %2d: first click %.2f ms after schedule, last %.2f ms; slope %+.2f ppm; click spacings %@ samples",
                             output, a * 1000, b * 1000, (b - a) / span * 1e6, "\(spacings.sorted())"))
            }
        }
        XCTAssertEqual(Set(firsts).count, 1, "T20: every output's click on the same sample: \(firsts)")
        if env("TABLEAUX_LOOPBACK_SILENT") != nil {
            for c in peaks.indices where !outputs.contains(c + 1) {
                XCTAssertLessThan(peaks[c], 0.0005, "output \(c + 1) should be silent")
            }
        }
    }

    /// One tone's amplitude in a signal, by the GOERTZEL ALGORITHM: a single bin
    /// of a Fourier transform, all that's needed to ask "how much of this pitch?"
    private static func level(_ x: [Float], hz: Double, rate: Double) -> Double {
        let k = 2 * cos(2 * .pi * hz / rate)
        var a = 0.0, b = 0.0
        for v in x { (a, b) = (Double(v) + k * a - b, a) }
        return (max(0, a * a + b * b - k * a * b)).squareRoot() / Double(max(x.count, 1)) * 2
    }
}
