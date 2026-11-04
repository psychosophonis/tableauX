import AVFoundation
import Foundation

// [claude] v5: reading sound sources and writing the bake (docs/architecture.md
// § The bake). This is the one part of PlayerCore that touches files through
// AVFoundation. It plays nothing and needs no screen or sound device, so its
// result can be tested sample by sample.

public enum AudioBakeError: LocalizedError, Equatable {
    case nothingToBake
    case tooLong(gigabytes: Double)

    public var errorDescription: String? {
        switch self {
        case .nothingToBake: return "There is no sound to prepare."
        case .tooLong(let gb):
            return String(format: "The sound would be a %.1f GB file, over the 4 GB a WAV can hold. Use fewer outputs or a shorter work.", gb)
        }
    }
}

/// Reads one source's audio as interleaved 32-bit floats, a block at a time.
///
/// AVASSETREADER is used for every source, video or sound file, because it does
/// three jobs in one: it finds the first audio track in any container, removes
/// AAC's encoder delay (`proofs/audio-decode-probe.swift` found the click at its
/// true time in every format), and resamples to the rate asked for.
///
/// It STREAMS rather than loading the file: 16 channels for an hour is 11 GB of
/// floats, and the bake only ever needs the next block of each source.
private final class SourceReader {
    let channels: Int
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: [Float] = []
    private var position = 0

    /// nil if the asset has no audio track.
    init?(url: URL, sampleRate: Double?) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let format = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        channels = Int(basic.mChannelsPerFrame)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate ?? basic.mSampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        // Over two channels the reader insists on a layout. DISCRETE IN ORDER says
        // "these are numbered channels, not speakers", so nothing gets remapped.
        if channels > 2, let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    }

    /// Up to `frames` frames, interleaved; fewer (or none) at the end of the file.
    func read(frames: Int) throws -> [Float] {
        let wanted = frames * channels
        var out: [Float] = []
        out.reserveCapacity(wanted)
        while out.count < wanted {
            if position >= pending.count {
                guard let sample = output.copyNextSampleBuffer() else {
                    if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
                    break
                }
                pending = Self.floats(sample)
                position = 0
                continue
            }
            let n = min(wanted - out.count, pending.count - position)
            out.append(contentsOf: pending[position..<position + n])
            position += n
        }
        return out
    }

    private static func floats(_ sample: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let bytes = CMBlockBufferGetDataLength(block)
        var out = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
        out.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
        return out
    }
}

public enum AudioBake {
    static let blockFrames = 48_000

    /// Measures a source: channels, rate, length, and how its two channels relate.
    ///
    /// The whole file is read, not a sample of it: a dual-mono file whose sides
    /// differ only in its last minute is real stereo. RMS (root mean square) is
    /// the level measure because it reflects a signal's energy over time rather
    /// than one loud sample. A file with no audio track gets `channels: 0`,
    /// because a video with no sound is a fact to report, not a failure.
    public static func analyse(_ url: URL) async throws -> AudioFacts {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let format = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let source = try await SourceReader(url: url, sampleRate: nil) else {
            return AudioFacts(channels: 0, duration: duration)
        }
        var stereo = StereoKind.different
        if source.channels == 2 {
            var left = 0.0, right = 0.0, difference = 0.0, count = 0
            while true {
                let block = try source.read(frames: blockFrames)
                guard !block.isEmpty else { break }
                var i = 0
                while i + 1 < block.count {
                    let l = Double(block[i]), r = Double(block[i + 1])
                    left += l * l; right += r * r; difference += (l - r) * (l - r)
                    i += 2
                }
                count += block.count / 2
            }
            let n = Double(max(count, 1))
            stereo = AudioRouting.classify(left: (left / n).squareRoot(), right: (right / n).squareRoot(),
                                           difference: (difference / n).squareRoot())
        }
        return AudioFacts(channels: source.channels, sampleRate: basic.mSampleRate, duration: duration, stereo: stereo)
    }

    /// Writes the plan's single multichannel WAV.
    ///
    /// Written to a temporary name and then renamed: a RENAME IS ATOMIC, so a bake
    /// interrupted half way can never be mistaken for a finished one by the next
    /// launch, which decides "already baked" only from the file existing.
    ///
    /// `sources[i]` is route i's file. `looping`: a shorter source repeats on its
    /// own length (a work with `shorter: loop`) instead of going silent, so its
    /// sound stays with its looping picture. `minimumLength`: run at least this
    /// long, for a looping work longer than its sound.
    public static func bake(plan: AudioRouting.Plan, sources: [URL], to destination: URL,
                            minimumLength: Double = 0, looping: Bool = false) async throws {
        guard plan.outputs > 0, plan.sampleRate > 0 else { throw AudioBakeError.nothingToBake }
        let rate = plan.sampleRate, outputs = plan.outputs
        let length = max(plan.length, minimumLength)
        let total = Int((length * rate).rounded())
        let bytes = Double(total) * Double(outputs) * 3
        guard bytes < 4_000_000_000 else { throw AudioBakeError.tooLong(gigabytes: bytes / 1e9) }

        // 24-bit integer with a discrete layout: what AVPlayer was shown to deliver
        // to separate outputs (`proofs/audio-format-probe.swift`). NEVER a CAF: it
        // plays in complete silence, with no error, in the same test.
        //
        // Two decisions worth seeing. A floating-point source louder than full scale
        // CLIPS here, since integers stop at ±1.0; 32-bit float would keep it, at a
        // third more disk and a 4 GB limit reached sooner. And there's no DITHER (the
        // low-level noise normally added when reducing bit depth, which hides the
        // distortion of rounding). At 24 bits that rounding sits near −144 dBFS, far
        // below any room's noise, so dither would add nothing audible here.
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(outputs)) else {
            throw AudioBakeError.nothingToBake
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
        var settings = format.settings
        settings[AVLinearPCMBitDepthKey] = 24
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false      // a file's samples are always interleaved on disk

        // Each source with a feed, its reader, and how long one play of it is.
        var streams: [Int: LoopingStream] = [:]
        for source in Set(plan.feeds.map(\.source)) {
            let url = sources[source]
            let seconds = try await AVURLAsset(url: url).load(.duration).seconds
            streams[source] = try await LoopingStream(url: url, sampleRate: rate, period: Int((seconds * rate).rounded()), looping: looping)
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).wav")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            // The file closes when `file` leaves this scope, which writes its
            // header; so the rename below must come after the scope ends.
            do {
                let file = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(blockFrames)),
                      let channels = buffer.floatChannelData else { throw AudioBakeError.nothingToBake }
                var written = 0
                while written < total {
                    let frames = min(blockFrames, total - written)
                    buffer.frameLength = AVAudioFrameCount(frames)
                    for c in 0..<outputs { channels[c].update(repeating: 0, count: frames) }
                    var blocks: [Int: [Float]] = [:]
                    for (source, stream) in streams { blocks[source] = try await stream.read(frames: frames) }
                    for feed in plan.feeds {
                        guard let block = blocks[feed.source], let stream = streams[feed.source] else { continue }
                        // The average of the channels, so a sum can't clip: two
                        // full-scale channels added would reach 2.0. Dividing by the
                        // count is EQUAL-GAIN SUMMING. The level it gives depends on how
                        // alike the channels are: identical channels keep their level,
                        // uncorrelated stereo comes out about 3 dB quieter, and a file
                        // with one silent side loses 6 dB. That last case is why a
                        // one-sided file takes its live channel instead of being summed.
                        let gain = 1 / Float(feed.channels.count)
                        let target = channels[feed.output - 1]
                        for ch in feed.channels where ch < stream.channels {
                            // The reader's samples are INTERLEAVED (L R L R …: one
                            // frame after another) and the buffer's are PLANAR (one
                            // array per channel). So this walks the block with a
                            // STRIDE of the channel count, from this channel's offset.
                            var i = ch, f = 0
                            while i < block.count, f < frames {
                                target[f] += block[i] * gain
                                i += stream.channels
                                f += 1
                            }
                        }
                    }
                    try file.write(from: buffer)
                    written += frames
                }
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// One source as an endless or silence-padded stream.
///
/// Each play lasts exactly `period` frames, trimmed or padded if the decoder gives
/// a few more or fewer. This avoids CUMULATIVE ERROR: a decoded length can differ
/// from the container's by some samples, and if each repeat simply followed the last,
/// that small error would add up with every loop, walking the sound away from its
/// picture. Worked out once from the source's duration and held fixed, the Nth
/// repeat starts at exactly N × period, so the error can't grow. It's the same
/// reason the rest of this app derives time from a shared start and never adds
/// durations up.
private final class LoopingStream {
    let channels: Int
    private let url: URL
    private let sampleRate: Double
    private let period: Int
    private let looping: Bool
    private var reader: SourceReader?
    private var played = 0

    init?(url: URL, sampleRate: Double, period: Int, looping: Bool) async throws {
        guard let first = try await SourceReader(url: url, sampleRate: sampleRate) else { return nil }
        self.url = url; self.sampleRate = sampleRate; self.period = period; self.looping = looping
        reader = first
        channels = first.channels
    }

    func read(frames: Int) async throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(frames * channels)
        var needed = frames
        while needed > 0 {
            if played >= period {
                guard looping, period > 0 else { break }
                reader = try await SourceReader(url: url, sampleRate: sampleRate)
                played = 0
            }
            let take = min(needed, period - played)
            let got = try reader?.read(frames: take) ?? []
            out.append(contentsOf: got)
            let short = take - got.count / channels
            if short > 0 { out.append(contentsOf: repeatElement(Float(0), count: short * channels)) }
            played += take
            needed -= take
        }
        if needed > 0 { out.append(contentsOf: repeatElement(Float(0), count: needed * channels)) }
        return out
    }
}
