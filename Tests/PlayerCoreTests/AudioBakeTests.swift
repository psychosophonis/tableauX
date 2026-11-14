import AVFoundation
import XCTest
@testable import PlayerCore

/// [claude] v5: real files in, a real WAV out, read back sample by sample
/// (docs/architecture.md § The bake; T19, T22).
final class AudioBakeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    /// One channel per array, written as a WAV, or AAC for an .m4a.
    private func write(_ channels: [[Float]], _ name: String, rate: Double = 48000) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count)))
        var settings = format.settings
        if name.hasSuffix(".m4a") {
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                        AVNumberOfChannelsKey: channels.count, AVEncoderBitRateKey: 192_000]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
        buffer.frameLength = buffer.frameCapacity
        for c in channels.indices { channels[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: channels[c].count) } }
        try file.write(from: buffer)
        return url
    }

    private func tone(_ hz: Double, frames: Int = 48000, rate: Double = 48000) -> [Float] {
        (0..<frames).map { Float(0.25 * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// The bake's channels as floats.
    private func read(_ url: URL) throws -> (channels: [[Float]], format: AVAudioFormat) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let n = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        return ((0..<n).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: frames)) }, file.processingFormat)
    }

    private func rms(_ x: [Float]) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot()
    }

    private func bake(_ routes: [AudioRoute], _ sources: [URL], minimumLength: Double = 0, looping: Bool = false) async throws -> [[Float]] {
        var facts: [AudioFacts?] = []
        for s in sources { facts.append(try await AudioBake.analyse(s)) }
        let plan = AudioRouting.plan(routes: routes, facts: facts)
        XCTAssertTrue(plan.problems.isEmpty, "\(plan.problems)")
        let out = dir.appendingPathComponent("baked.wav")
        try await AudioBake.bake(plan: plan, sources: sources, to: out, minimumLength: minimumLength, looping: looping)
        return try read(out).channels
    }

    // MARK: Analysis

    func testAnalyseReadsTheStereoCases() async throws {
        let a = tone(440), b = tone(620), zero = [Float](repeating: 0, count: 48000)
        let kind: ([[Float]], String) async throws -> StereoKind = { c, n in
            try await AudioBake.analyse(self.write(c, n)).stereo
        }
        let cases: [([[Float]], String, StereoKind)] = [
            ([a, a], "dual.wav", .dual), ([a, b], "wide.wav", .different),
            ([a, zero], "left.wav", .leftOnly), ([zero, a], "right.wav", .rightOnly), ([zero, zero], "silent.wav", .silent),
        ]
        for (channels, name, expected) in cases {
            let got = try await kind(channels, name)
            XCTAssertEqual(got, expected, name)
        }
    }

    /// The hedge has to hold after a lossy encoder, not only on clean WAVs.
    func testDualMonoStaysDualThroughAppleAAC() async throws {
        let a = tone(440)
        let facts = try await AudioBake.analyse(try write([a, a], "dual.m4a"))
        XCTAssertEqual(facts.channels, 2)
        XCTAssertEqual(facts.stereo, .dual)
    }

    func testAnalyseReportsAFileWithNoAudioTrackWithoutFailing() async throws {
        let url = dir.appendingPathComponent("empty.mov")
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        w.add(input)
        w.startWriting()
        w.startSession(atSourceTime: .zero)
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels)
        adaptor.append(try XCTUnwrap(pixels), withPresentationTime: .zero)
        input.markAsFinished()
        await w.finishWriting()
        let facts = try await AudioBake.analyse(url)
        XCTAssertEqual(facts.channels, 0)
    }

    // MARK: The bake

    /// T19: each source on its own outputs, the gap between them truly silent.
    func testRoutesLandOnTheirOutputsAndTheGapIsSilent() async throws {
        let a = try write([tone(440)], "a.wav")
        let s = try write([tone(620), tone(880)], "s.wav")
        let ch = try await bake([AudioRoute(file: "a", output: 2), AudioRoute(file: "s", output: 5)], [a, s])
        XCTAssertEqual(ch.count, 6)
        for silent in [0, 2, 3] { XCTAssertEqual(rms(ch[silent]), 0, accuracy: 1e-6, "output \(silent + 1)") }
        // 24-bit storage rounds to within one step (about 1.2e-7 of full scale).
        for (out, src) in [(1, tone(440)), (4, tone(620)), (5, tone(880))] {
            XCTAssertLessThan(rms(zip(ch[out], src).map { $0 - $1 }), 1e-6, "output \(out + 1)")
        }
    }

    /// A one-output bake is still two channels: as a true mono file AVFoundation
    /// could send it to every speaker of the device.
    func testASingleMonoRouteBakesTwoChannels() async throws {
        let ch = try await bake([AudioRoute(file: "a", output: 1)], [try write([tone(440)], "a.wav")])
        XCTAssertEqual(ch.count, 2)
        XCTAssertEqual(rms(ch[1]), 0, accuracy: 1e-6)
    }

    func testTheBakeIsADiscreteLayoutWAV() async throws {
        let url = dir.appendingPathComponent("baked.wav")
        _ = try await bake([AudioRoute(file: "a", output: 3)], [try write([tone(440)], "a.wav")])
        XCTAssertEqual(try read(url).format.channelLayout?.layoutTag, kAudioChannelLayoutTag_DiscreteInOrder | 3)
        XCTAssertEqual(try AVAudioFile(forReading: url).fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
    }

    func testASumIsTheAverageSoItCannotClip() async throws {
        let full = [Float](repeating: 0.9, count: 4800)
        let ch = try await bake([AudioRoute(file: "s", output: 1, take: .sum)], [try write([full, full], "s.wav")])
        XCTAssertEqual(ch[0][100], 0.9, accuracy: 1e-5)
    }

    func testDualMonoGoesToOneOutputWithNoSpill() async throws {
        let a = tone(440)
        let ch = try await bake([AudioRoute(file: "d", output: 1)], [try write([a, a], "d.wav")])
        XCTAssertGreaterThan(rms(ch[0]), 0.1)
        XCTAssertEqual(rms(ch[1]), 0, accuracy: 1e-6)
    }

    func testAShorterSourceGoesSilentAndARateIsConverted() async throws {
        let long = try write([tone(440, frames: 96000)], "long.wav")
        let short = try write([tone(300, frames: 44100, rate: 44100)], "short.wav", rate: 44100)
        let ch = try await bake([AudioRoute(file: "l", output: 1), AudioRoute(file: "s", output: 2)], [long, short])
        XCTAssertEqual(ch[0].count, 96000, "the longest source's length, at the highest rate")
        XCTAssertGreaterThan(rms(Array(ch[1][1000..<47000])), 0.1, "resampled and playing")
        XCTAssertEqual(rms(Array(ch[1][49000...])), 0, accuracy: 1e-5, "silent after its end")
    }

    func testAShorterSourceLoopsOnItsOwnLengthWhenAsked() async throws {
        let click = (0..<4800).map { Float($0 == 0 ? 0.9 : 0) }           // a click every 0.1 s when looped
        let ch = try await bake([AudioRoute(file: "c", output: 1)], [try write([click], "c.wav")], minimumLength: 0.5, looping: true)
        XCTAssertEqual(ch[0].count, 24000)
        for k in 0..<5 { XCTAssertEqual(ch[0][k * 4800], 0.9, accuracy: 1e-5, "repeat \(k) on its exact sample") }
    }

    /// T22: a video's own sound lands at its true time, AAC's encoder delay
    /// removed. Uses ffmpeg to make a real video; skipped where it isn't installed.
    func testAVideosSoundLandsAtItsTrueTime() async throws {
        let ffmpeg = "/usr/local/bin/ffmpeg"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: ffmpeg), "ffmpeg not installed")
        let video = dir.appendingPathComponent("clip.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-hide_banner", "-loglevel", "error",
                       "-f", "lavfi", "-i", "color=c=black:s=64x64:r=30:d=3",
                       "-f", "lavfi", "-i", "aevalsrc=if(lt(abs(t-1)\\,0.0005)\\,0.9\\,0):s=44100:d=3",
                       "-c:v", "libx264", "-c:a", "aac", "-b:a", "192k", "-shortest", video.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        // Baked at 48 kHz next to a 48 kHz file: the rate conversion is in the path too.
        let other = try write([[Float](repeating: 0, count: 144000)], "bed.wav")
        let ch = try await bake([AudioRoute(screen: 0, output: 1), AudioRoute(file: "bed", output: 2)], [video, other])
        let peak = ch[0].map(abs).max() ?? 0
        let at = try XCTUnwrap(ch[0].firstIndex { abs($0) > peak * 0.5 })
        XCTAssertEqual(Double(at) / 48000, 0.9995, accuracy: 0.002, "the click window opens 0.5 ms before 1 s")
    }

    // MARK: Stereo fold-down (§ Stereo fold-down; T24)

    private func foldPlan(_ pans: [Double], _ sources: [URL]) async throws -> AudioRouting.Plan {
        var facts: [AudioFacts?] = []
        for s in sources { facts.append(try await AudioBake.analyse(s)) }
        let routes = sources.indices.map { AudioRoute(file: "s\($0)", output: $0 + 1) }
        let plan = AudioRouting.plan(routes: routes, facts: facts)
        return AudioRouting.fold([.init(plan: plan, sources: routes.count, pan: { pans[$0 - 1] })])
    }

    func testAFoldDownPutsEachOutputWhereItsPanSays() async throws {
        let a = try write([tone(440)], "a.wav"), b = try write([tone(620)], "b.wav"), c = try write([tone(880)], "c.wav")
        let plan = try await foldPlan([-1, 1, 0], [a, b, c])
        let out = dir.appendingPathComponent("fold.wav")
        try await AudioBake.bake(plan: plan, sources: [a, b, c], to: out, preventClipping: true)
        let ch = try read(out).channels
        XCTAssertEqual(ch.count, 2)
        // Left holds a + c/√2, right holds b + c/√2, unchanged because nothing clips.
        let centre = tone(880).map { $0 * Float(0.5.squareRoot()) }
        XCTAssertLessThan(rms(zip(zip(tone(440), centre), ch[0]).map { $0.0 + $0.1 - $1 }), 1e-5)
        XCTAssertLessThan(rms(zip(zip(tone(620), centre), ch[1]).map { $0.0 + $0.1 - $1 }), 1e-5)
    }

    /// Every speaker hard left, at near full scale: the sum would reach 3.6.
    func testAFoldDownThatWouldClipIsTurnedDownAndKeepsItsBalance() async throws {
        let loud = [Float](repeating: 0.9, count: 4800), half = [Float](repeating: 0.45, count: 4800)
        let sources = [try write([loud], "a.wav"), try write([loud], "b.wav"), try write([loud], "c.wav"), try write([half], "d.wav")]
        let plan = try await foldPlan([-1, -1, -1, 1], sources)
        let out = dir.appendingPathComponent("fold.wav")
        try await AudioBake.bake(plan: plan, sources: sources, to: out, preventClipping: true)
        let ch = try read(out).channels
        let scale = Float(1 / 2.7)
        XCTAssertEqual(ch[0][100], 1, accuracy: 1e-4, "the loudest side reaches full scale and no further")
        XCTAssertEqual(ch[1][100], 0.45 * scale, accuracy: 1e-4, "the other side comes down by the same gain")
    }

    func testAQuietFoldDownIsNeverTurnedUp() async throws {
        let quiet = [Float](repeating: 0.01, count: 4800)
        let source = try write([quiet], "a.wav")
        let plan = try await foldPlan([-1], [source])
        let out = dir.appendingPathComponent("fold.wav")
        try await AudioBake.bake(plan: plan, sources: [source], to: out, preventClipping: true)
        XCTAssertEqual(try read(out).channels[0][100], 0.01, accuracy: 1e-5)
    }

    func testTooLongForAWAVStopsWithAMessage() async throws {
        var plan = AudioRouting.Plan()
        plan.outputs = 16; plan.sampleRate = 48000; plan.length = 2 * 3600
        plan.feeds = [.init(output: 1, source: 0, channels: [0])]
        do {
            try await AudioBake.bake(plan: plan, sources: [try write([tone(440)], "a.wav")], to: dir.appendingPathComponent("x.wav"))
            XCTFail("should refuse")
        } catch let e as AudioBakeError {
            guard case .tooLong = e else { return XCTFail("\(e)") }
        }
    }

    func testAFailedBakeLeavesNoFileBehind() async throws {
        var plan = AudioRouting.Plan()
        plan.outputs = 2; plan.sampleRate = 48000; plan.length = 1
        plan.feeds = [.init(output: 1, source: 0, channels: [0])]
        let out = dir.appendingPathComponent("x.wav")
        do { try await AudioBake.bake(plan: plan, sources: [dir.appendingPathComponent("missing.wav")], to: out) } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: v6 — mixing on one output (§ v6; T25, T26)

    /// A burst of tone in one time slot and silence everywhere else, so a channel can
    /// be identified in the bake by WHERE IN TIME its energy is. The alternative,
    /// telling channels apart by frequency, needs a filter to measure; separating them
    /// in time needs only the RMS of a slice, which is what makes this test readable.
    private func burst(slot: Int, of slots: Int, frames: Int = 48000, amplitude: Float = 0.5) -> [Float] {
        let width = frames / slots
        return (0..<frames).map { n in
            n / width == slot ? amplitude * Float(sin(2 * .pi * 440 * Double(n) / 48000)) : 0
        }
    }

    /// A staggered ring through real files: three stereo sources on
    /// outputs 1-2, 2-3, 3-1. Every output must carry exactly two channels — the left
    /// of its own source and the right of the one before it — and nothing else.
    func testAStaggeredRingRoutesEveryChannelThroughTheBake() async throws {
        let slots = 6
        var sources: [URL] = []
        for k in 0..<3 {
            sources.append(try write([burst(slot: 2 * k, of: slots), burst(slot: 2 * k + 1, of: slots)], "ring\(k).wav"))
        }
        let routes = AudioRouting.stagger(sources.map { AudioRoute(file: $0.path, output: 1) })
        var facts: [AudioFacts?] = []
        for s in sources { facts.append(try await AudioBake.analyse(s)) }
        let plan = AudioRouting.plan(routes: routes, facts: facts)
        XCTAssertTrue(plan.mixed)
        XCTAssertTrue(plan.problems.isEmpty, "\(plan.problems)")
        let out = dir.appendingPathComponent("ring.wav")
        try await AudioBake.bake(plan: plan, sources: sources, to: out, preventClipping: plan.mixed)
        let channels = try read(out).channels
        XCTAssertEqual(channels.count, 3)

        // output 1: source 0's left (slot 0) and source 2's right (slot 5, the wrap)
        // output 2: source 0's right (slot 1) and source 1's left (slot 2)
        // output 3: source 1's right (slot 3) and source 2's left (slot 4)
        let expected = [[0, 5], [1, 2], [3, 4]]
        let width = 48000 / slots
        for output in 0..<3 {
            for slot in 0..<slots {
                let slice = Array(channels[output][slot * width ..< (slot + 1) * width])
                if expected[output].contains(slot) {
                    XCTAssertGreaterThan(rms(slice), 0.3, "output \(output + 1) should carry slot \(slot)")
                } else {
                    XCTAssertLessThan(rms(slice), 0.0003, "output \(output + 1) leaked slot \(slot)")  // −60 dB
                }
            }
        }
    }

    /// T26. Two sources meeting in phase on one output reach the sum of their
    /// amplitudes; the bake brings the whole mix inside full scale with ONE gain, so
    /// an output that was never in danger is turned down by exactly the same amount.
    /// That is what keeps the balance between speakers — the thing a ring is made of.
    func testAMixThatWouldClipIsTurnedDownAsAWhole() async throws {
        let hot = tone(440).map { $0 * 3.2 }            // 0.25 × 3.2 = 0.8
        let quiet = tone(440).map { $0 * 2 }            // 0.5
        let a = try write([hot], "hot-a.wav"), b = try write([hot], "hot-b.wav"), c = try write([quiet], "quiet.wav")
        let routes = [AudioRoute(file: a.path, output: 1), AudioRoute(file: b.path, output: 1),
                      AudioRoute(file: c.path, output: 2)]
        var facts: [AudioFacts?] = []
        for s in [a, b, c] { facts.append(try await AudioBake.analyse(s)) }
        let plan = AudioRouting.plan(routes: routes, facts: facts)
        XCTAssertTrue(plan.mixed)
        let out = dir.appendingPathComponent("mixed.wav")
        try await AudioBake.bake(plan: plan, sources: [a, b, c], to: out, preventClipping: plan.mixed)
        let channels = try read(out).channels

        let peak = { (x: [Float]) in x.map(abs).max() ?? 0 }
        // 0.8 + 0.8 = 1.6, so the gain is 1/1.6 = 0.625.
        XCTAssertEqual(Double(peak(channels[0])), 1.0, accuracy: 0.01, "brought to full scale, not beyond")
        XCTAssertEqual(Double(peak(channels[1])), 0.5 * 0.625, accuracy: 0.01, "the same gain, so balance holds")
    }

    func testAMixThatWouldNotClipIsLeftAlone() async throws {
        let a = try write([tone(440)], "soft-a.wav"), b = try write([tone(440)], "soft-b.wav")
        let routes = [AudioRoute(file: a.path, output: 1), AudioRoute(file: b.path, output: 1)]
        var facts: [AudioFacts?] = []
        for s in [a, b] { facts.append(try await AudioBake.analyse(s)) }
        let plan = AudioRouting.plan(routes: routes, facts: facts)
        let out = dir.appendingPathComponent("soft.wav")
        try await AudioBake.bake(plan: plan, sources: [a, b], to: out, preventClipping: plan.mixed)
        // 0.25 + 0.25 summed in phase, nowhere near full scale: no gain at all.
        XCTAssertEqual(Double((try read(out).channels[0]).map(abs).max() ?? 0), 0.5, accuracy: 0.01)
    }
}
