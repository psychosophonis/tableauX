// PROBE: which file formats does AVPlayer deliver discretely?
//
// Idea at risk: "the container doesn't matter: the same samples with the same discrete
// channel layout play the same way." This began as a diagnosis. A baked CAF played in
// silence while the player reported status ready, rate 1 and time advancing, and
// changing one variable at a time ruled out composition, clock and scheduling. So this
// varies only the file, keeping the WAV that's known to work as the CONTROL: if the
// control went silent too, the fault would be in the test, not the format.
//
// FALSIFIED BY: formats behaving differently with identical samples and layout.
//
// WHAT IT TAUGHT (2026-11-05, Pro Tools Audio Bridge 16): FALSIFIED.
//   WAV, 8 ch float32 (control), 10 ch float32, 10 ch int24, 16 ch int24: all discrete.
//   CAF, 8 ch float32, 8 ch int24, 10 ch int24: complete silence, no error, status ready.
// The failure is SILENT, the worst kind, since nothing in the player's state shows it.
// Only measuring what arrived could find it. So bakes must stay WAV.
// Limit: why CAF fails wasn't investigated, and this is one macOS version and one
// virtual device. Formats not tried: RF64 and MOV, which matter for bakes over 4 GB.
// The first part of this file makes baked.caf, as the pipeline probe does.
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

// THE BAKE: read each file, copy its channels to its outputs, write one CAF.
let t0 = Date()
let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(OUTS))!
let outFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channelLayout: layout)
let baked = tmp.appendingPathComponent("baked.caf"); try? FileManager.default.removeItem(at: baked)
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


func make(_ n: Int, ext: String, bits: Int, float: Bool, chan: Int? = nil) throws -> URL {
    let l = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(n))!
    let f = AVAudioFormat(standardFormatWithSampleRate: sr, channelLayout: l)
    let u = tmp.appendingPathComponent("t\(n)-\(bits)\(float ? "f" : "i").\(ext)"); try? FileManager.default.removeItem(at: u)
    var st = f.settings; st[AVLinearPCMBitDepthKey] = bits; st[AVLinearPCMIsFloatKey] = float
    do {
        let o = try AVAudioFile(forWriting: u, settings: st, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(fileLen))!; b.frameLength = b.frameCapacity
        for c in 0..<n { let t = tone(300 * Double(c + 1)); t.withUnsafeBufferPointer { b.floatChannelData![c].update(from: $0.baseAddress!, count: fileLen) } }
        try o.write(from: b)
    }
    return u
}
func peaks(_ u: URL) -> String {
    guard let f = try? AVAudioFile(forReading: u) else { return "unreadable" }
    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 48000)!; try? f.read(into: b)
    let pk = (0..<Int(b.format.channelCount)).map { c in (0..<Int(b.frameLength)).map { abs(b.floatChannelData![c][$0]) }.max() ?? 0 }
    return "file: \(b.format.channelCount) ch, tag \(b.format.channelLayout?.layoutTag ?? 0), peak min \(pk.min() ?? 0)"
}
@MainActor func t(_ name: String, _ u: URL) async throws {
    let p = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: u)))
    p.audioOutputDeviceUniqueID = uid
    while p.currentItem?.status == .unknown { try await Task.sleep(for: .milliseconds(20)) }
    let cap = try await capture(2.5, start: { p.play() }, stop: { })
    p.pause()
    let live = cap.ch.enumerated().filter { ($0.element.map { abs($0) }.max() ?? 0) > 0.001 }.map { $0.offset + 1 }
    print("\(name): outs \(live)  rate \(p.rate)  (\(peaks(u)))")
}
Task { @MainActor in
    try await t("wav 8 float32 (control: test A)", try make(8, ext: "wav", bits: 32, float: true))
    try await t("wav 10 float32                 ", try make(10, ext: "wav", bits: 32, float: true))
    try await t("wav 10 int24                   ", try make(10, ext: "wav", bits: 24, float: false))
    try await t("caf 8 float32                  ", try make(8, ext: "caf", bits: 32, float: true))
    try await t("caf 8 int24                    ", try make(8, ext: "caf", bits: 24, float: false))
    try await t("caf 10 int24                   ", try make(10, ext: "caf", bits: 24, float: false))
    try await t("wav 16 int24                   ", try make(16, ext: "wav", bits: 24, float: false))
    try await t("baked.caf                      ", baked)
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(60))
