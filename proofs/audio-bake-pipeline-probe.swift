// PROBE: "bake a folder of files into one discrete multichannel file, then play it
// through the app's existing AVPlayer pipeline" (Playback.makeItem + build + start).
// Tries to kill it where the plain-file test could not:
//  1 AVMutableComposition repeats might lose the discrete layout (mixdown).
//  2 Loop seams might drop or add samples (work loops are the app's normal case).
//  3 setRate(atHostTime:) + masterClock might not hold with audio-only items.
//  4 Routing with gaps: 4 monos on outs 1-4, a stereo file on outs 9-10, 5-8 silent.
//  5 Empty ranges (a shorter screen's "black") might upset it.
// Files are 10 s; a click on the first sample of every channel, tone after it.
//
// FALSIFIED BY: any channel on the wrong output, click spacing other than exactly
// 480000 samples (576000 with gaps), or sound on an output that should be silent.
//
// WHAT IT TAUGHT (2026-11-05, Pro Tools Audio Bridge 16): survived all five. Spacing
// exact, 0 samples between channels, outputs 5-8 silent, crosstalk about -79 dB,
// arrival 0.95 ms after schedule. The first run baked a CAF and everything was
// silent, with a healthy-looking player, which led to audio-format-probe.swift.
// Limit: this virtual device follows the host clock (0.00 ppm), so exact spacing here
// says nothing about a real interface. See audio-clock-probe.swift and target T23.
import AVFoundation
import CoreAudio
import Foundation

let sr = 48000.0, fileLen = Int(sr * 10), OUTS = 10
var tbi = mach_timebase_info_data_t(); mach_timebase_info(&tbi)
func hs(_ h: UInt64) -> Double { Double(h) * Double(tbi.numer) / Double(tbi.denom) / 1e9 }
func hostTicks(_ s: Double) -> UInt64 { UInt64(s * 1e9 * Double(tbi.denom) / Double(tbi.numer)) }
func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func str(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel); var v: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr, let v else { return "" }
    return v.takeRetainedValue() as String
}
var a0 = addr(kAudioHardwarePropertyDevices); var sz0: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a0, 0, nil, &sz0)
var ids = [AudioObjectID](repeating: 0, count: Int(sz0) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a0, 0, nil, &sz0, &ids)
guard let dev = ids.first(where: { str($0, kAudioObjectPropertyName).contains("Audio Bridge 16") }) else { exit(1) }
let uid = str(dev, kAudioDevicePropertyDeviceUID)

// Source files as a student would hand them in: 4 monos and 1 stereo.
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bakeprobe"); try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
func tone(_ f: Double) -> [Float] { (0..<fileLen).map { $0 == 0 ? 0.9 : Float(0.2 * sin(2 * .pi * f * Double($0) / sr)) } }
func writeFile(_ ch: [[Float]], _ name: String) throws -> URL {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: AVAudioChannelCount(ch.count))!
    let u = tmp.appendingPathComponent(name); try? FileManager.default.removeItem(at: u)
    let f = try AVAudioFile(forWriting: u, settings: fmt.settings)
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fileLen))!; b.frameLength = b.frameCapacity
    for c in ch.indices { ch[c].withUnsafeBufferPointer { b.floatChannelData![c].update(from: $0.baseAddress!, count: fileLen) } }
    try f.write(from: b); return u
}
let freqs = [300.0, 600, 900, 1200, 1500, 1800]
var routes: [(URL, Int)] = []    // file, first output (0-based)
for i in 0..<4 { routes.append((try writeFile([tone(freqs[i])], "ch\(i + 1).wav"), i)) }
routes.append((try writeFile([tone(freqs[4]), tone(freqs[5])], "st_9.wav"), 8))

// THE BAKE: read each file, copy its channels to its outputs, write one WAV (AVPlayer is silently mute on a CAF: format-matrix-probe).
let t0 = Date()
let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(OUTS))!
let outFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channelLayout: layout)
let baked = tmp.appendingPathComponent("baked.wav"); try? FileManager.default.removeItem(at: baked)
do {
    var settings = outFmt.settings; settings[AVLinearPCMBitDepthKey] = 24; settings[AVLinearPCMIsFloatKey] = false
    let out = try AVAudioFile(forWriting: baked, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let mix = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(fileLen))!; mix.frameLength = mix.frameCapacity
    for c in 0..<OUTS { memset(mix.floatChannelData![c], 0, fileLen * 4) }
    for (u, first) in routes {
        let f = try AVAudioFile(forReading: u)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(fileLen))!; try f.read(into: b)
        for c in 0..<Int(f.processingFormat.channelCount) { mix.floatChannelData![first + c].update(from: b.floatChannelData![c], count: fileLen) }
    }
    try out.write(from: mix)
}
print(String(format: "baked %d outs, 10 s, in %.2f s", OUTS, Date().timeIntervalSince(t0)))

// Capture with host stamps, so an arrival can be compared to its scheduled time.
final class Cap { var ch: [[Float]] = []; var marks: [(idx: Int, host: Double)] = [] }
func capture(_ seconds: Double, start: () throws -> Void, stop: () -> Void) async throws -> Cap {
    let cap = Cap(); let q = DispatchQueue(label: "c"); var id: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&id, dev, q) { _, input, inTime, _, _ in
        var c = 0; let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        cap.marks.append((cap.ch.first?.count ?? 0, hs(inTime.pointee.mHostTime)))
        for b in bufs { let nc = Int(b.mNumberChannels); guard nc > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(b.mDataByteSize) / 4 / nc
            for k in 0..<nc { if cap.ch.count <= c { cap.ch.append([]) }; for i in 0..<n { cap.ch[c].append(d[i * nc + k]) }; c += 1 } }
    }
    AudioDeviceStart(dev, id!); try await Task.sleep(for: .milliseconds(200))
    try start(); try await Task.sleep(for: .seconds(seconds)); stop()
    AudioDeviceStop(dev, id!); AudioDeviceDestroyIOProcID(dev, id!)
    return q.sync { cap }
}
func hostOf(_ i: Int, _ c: Cap) -> Double {
    guard let m = c.marks.last(where: { $0.idx <= i }) else { return 0 }
    return m.host + Double(i - m.idx) / sr
}
func clicks(_ x: [Float]) -> [Int] {
    var out: [Int] = [], i = 0
    while i < x.count { if abs(x[i]) > 0.7 { out.append(i); i += Int(sr) } else { i += 1 } }
    return out
}
func goertzel(_ x: ArraySlice<Float>, _ f: Double) -> Double {
    let w = 2 * .pi * f / sr, k = 2 * cos(w); var a = 0.0, b = 0.0
    for v in x { let t = Double(v) + k * a - b; b = a; a = t }
    return sqrt(max(0, a * a + b * b - k * a * b)) / Double(max(x.count, 1)) * 2
}

// Same steps as Playback.makeItem/build/startLoaded, audio only: file repeated in
// a composition, host master clock, no stall waiting, preroll, scheduled start.
@MainActor func play(_ name: String, empty: Bool) async throws {
    let asset = AVURLAsset(url: baked)
    let clip = try await asset.load(.duration)
    let comp = AVMutableComposition(); var cur = CMTime.zero
    for k in 0..<3 {
        try await comp.insertTimeRange(CMTimeRange(start: .zero, duration: clip), of: asset, at: cur); cur = cur + clip
        if empty && k < 2 { let e = CMTime(seconds: 2, preferredTimescale: 1_000_000_000); comp.insertEmptyTimeRange(CMTimeRange(start: cur, duration: e)); cur = cur + e }
    }
    let p = AVPlayer(playerItem: AVPlayerItem(asset: comp))
    p.audioOutputDeviceUniqueID = uid
    p.automaticallyWaitsToMinimizeStalling = false
    p.masterClock = CMClockGetHostTimeClock()
    p.actionAtItemEnd = .pause
    while p.currentItem?.status != .readyToPlay { try await Task.sleep(for: .milliseconds(20)) }
    _ = await p.preroll(atRate: 1)
    let total = cur.seconds
    var h0 = 0.0
    let cap = try await capture(total + 2.5, start: {
        h0 = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 1
        p.setRate(1, time: .zero, atHostTime: CMTime(seconds: h0, preferredTimescale: 1_000_000_000))
    }, stop: { p.pause() })
    print("\n== \(name): \(cap.ch.count) ch captured, \(cap.ch.first?.count ?? 0) samples")
    let want: [Int: Double] = [0: 300, 1: 600, 2: 900, 3: 1200, 8: 1500, 9: 1800]
    var firstClick: [Int] = [], fail = 0
    for (c, x) in cap.ch.enumerated() {
        let peak = x.map { abs($0) }.max() ?? 0
        if let f = want[c] {
            let cl = clicks(x); firstClick.append(cl.first ?? -1)
            let lv = freqs.map { goertzel(x[...], $0) }
            let others = freqs.filter { $0 != f }.map { goertzel(x[...], $0) }.max() ?? 0
            let spacing = zip(cl.dropFirst(), cl).map { $0 - $1 }
            print(String(format: "  out %2d  peak %.3f  own tone %.3f  loudest other %.5f  clicks %d  spacing ", c + 1, peak, lv[freqs.firstIndex(of: f)!], others, cl.count) + "\(spacing)")
        } else if peak > 0.0005 { print(String(format: "  out %2d SHOULD BE SILENT, peak %.4f", c + 1, peak)); fail += 1 }
    }
    let spread = (firstClick.max() ?? 0) - (firstClick.min() ?? 0)
    print("  first-click spread across channels: \(spread) samples; unexpected channels: \(fail)")
    if let f = firstClick.first, f >= 0 { print(String(format: "  scheduled -> arrival (includes device latency): %.2f ms", (hostOf(f, cap) - h0) * 1000)) }
}
Task { @MainActor in
    try await play("3 repeats, no gaps (spacing should be exactly 480000)", empty: false)
    try await play("3 repeats with 2 s empty ranges (spacing should be 576000)", empty: true)
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(110))
