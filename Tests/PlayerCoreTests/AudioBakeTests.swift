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
}
