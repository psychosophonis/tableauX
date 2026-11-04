// PROBE: can a video's own audio join the baked multichannel file without moving
// against its picture, and can dual mono be recognised after a lossy encoder?
//
// Idea 1 at risk: decoding a video's audio track with AVAssetReader lands samples at
// their true time. AAC adds ENCODER DELAY (priming: extra samples at the start, which
// the file's metadata says to skip). If the reader didn't skip them, sound would sit
// about 20-40 ms late against its picture.
// FALSIFIED BY: a click at 1.000 s decoding anywhere else.
//
// Idea 2 at risk: comparing L and R tells dual mono from true stereo. After AAC or MP3
// they aren't bit-identical, so a threshold has to separate near-identical from
// genuinely narrow stereo.
// FALSIFIED BY: dual mono and real stereo overlapping, so no threshold separates them.
//
// Make the files with make-audio-probe-media.sh; args: list of files.
//
// WHAT IT TAUGHT (2026-11-05):
// Idea 1 survived. The click's window opens at 999.50 ms and decodes at 999.50 ms in
// ffmpeg AAC (mp4, mov, 44.1 and 48 kHz), PCM in mov, and Apple AAC in m4a.
// Limits: this is the decoder alone. Comparing with the same video played muxed, the
// real test of sound against picture, was never run. Nor were exports from Premiere,
// After Effects or Resolve, whose encoders may write delay differently.
//
// Idea 2 was PARTLY FALSIFIED. L-R as dB of the signal:
//   dual mono:   WAV, MP3, Apple AAC -200; independent dither -61.7;
//                ffmpeg AAC, music-like -43.5; ffmpeg AAC, pure noise -13.2
//   real stereo: closest measured -39.1 (noise, Apple AAC), -25.8 (music-like)
// A -40 dB limit separates all of these except ffmpeg AAC on noise, which overlaps
// real stereo completely. The likely cause (not tested in isolation, though turning
// it off gave -200 and -84.7 dB) is PERCEPTUAL NOISE SUBSTITUTION: the encoder
// replaces noisy bands with fresh random noise, per channel, because the ear can't
// tell, so identical inputs come out different. A waveform comparison can't see through
// that. So the design changed: detection became a default, with every decision shown
// and overridable, instead of being trusted.
// A silent channel, by contrast, stayed exactly silent through every encoder tried.
import AVFoundation
import Foundation

func decode(_ url: URL, rate: Double?) async throws -> (ch: [[Float]], sr: Double) {
    let asset = AVURLAsset(url: url)
    guard let t = try await asset.loadTracks(withMediaType: .audio).first else { return ([], 0) }
    let r = try AVAssetReader(asset: asset)
    let fd = try await t.load(.formatDescriptions).first!
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)!.pointee
    let n = Int(asbd.mChannelsPerFrame), sr = rate ?? asbd.mSampleRate
    var s: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                            AVSampleRateKey: sr, AVNumberOfChannelsKey: n]
    if n > 2 { s[AVChannelLayoutKey] = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(n))!.layout.withMemoryRebound(to: UInt8.self, capacity: 1) { Data(bytes: $0, count: MemoryLayout<AudioChannelLayout>.size) } }
    let o = AVAssetReaderTrackOutput(track: t, outputSettings: s)
    r.add(o); r.startReading()
    var ch = [[Float]](repeating: [], count: n)
    while let b = o.copyNextSampleBuffer() {
        guard let bb = CMSampleBufferGetDataBuffer(b) else { continue }
        var len = 0; var p: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointerSafe(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &p)
        p!.withMemoryRebound(to: Float.self, capacity: len / 4) { f in for i in 0..<(len / 4) { ch[i % n].append(f[i]) } }
    }
    return (ch, sr)
}
func CMBlockBufferGetDataPointerSafe(_ b: CMBlockBuffer, atOffset: Int, lengthAtOffsetOut: UnsafeMutablePointer<Int>?, totalLengthOut: UnsafeMutablePointer<Int>?, dataPointerOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) {
    CMBlockBufferGetDataPointer(b, atOffset: atOffset, lengthAtOffsetOut: lengthAtOffsetOut, totalLengthOut: totalLengthOut, dataPointerOut: dataPointerOut)
}
func db(_ x: Double) -> Double { x <= 0 ? -200 : 20 * log10(x) }
func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(x.count, 1))) }
Task {
    for path in CommandLine.arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        let (ch, sr) = try await decode(url, rate: nil)
        guard let x = ch.first, !x.isEmpty else { print("\(url.lastPathComponent): no audio"); continue }
        let peak = x.map { abs($0) }.max() ?? 0
        let at = x.firstIndex { abs($0) > peak * 0.5 } ?? -1
        let line = String(format: "%-26@ %2d ch %6.0f Hz  %.4f s  first loud sample at %.2f ms",
                          url.lastPathComponent as NSString, ch.count, sr, Double(x.count) / sr, Double(at) / sr * 1000)
        var stereo = ""
        if ch.count == 2 {
            let diff = zip(ch[0], ch[1]).map { $0 - $1 }
            stereo = String(format: "  L−R relative to signal %.1f dB; L %.1f dB R %.1f dB", db(rms(diff[...]) / max(rms(ch[0][...]), 1e-12)), db(rms(ch[0][...])), db(rms(ch[1][...])))
        }
        print(line + stereo)
    }
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(60))
