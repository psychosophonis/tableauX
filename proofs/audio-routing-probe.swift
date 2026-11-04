// PROBE: can a folder of N mono files reach N chosen output channels, discretely
// and sample-aligned, and which audio API can do it?
//
// Idea at risk: "AVPlayer, already the engine here, can play discrete channels."
// Tries to kill it, and tests the alternative the same way:
//   A  AVPlayer + one 8-channel discrete WAV
//   B  AVPlayer + composition of 8 mono WAVs (the obvious folder approach)
//   C  AVAudioEngine + one render callback copying 8 mono buffers to chosen outputs
// Each source channel is a unique tone, with one click on the same sample in all.
// Output goes to a 16-channel virtual device; its input side is captured, so the
// result is what arrived, not what was asked for. That's a LOOPBACK TEST: it checks
// the outcome rather than trusting that the API did what it was told.
//
// FALSIFIED BY: a source on the wrong output or several, or clicks on different samples.
//
// WHAT IT TAUGHT (2026-11-05, Pro Tools Audio Bridge 16):
//   A survived: 8 sources on outputs 1-8, each alone, clicks 0 samples apart.
//   B FALSIFIED: all 8 mixed into one channel, peak 7.2 (far over full scale).
//   C survived, but it would mean writing streaming and drift correction by hand.
// The author expected A to fail and C to be the only way. A's result is what made
// the bake possible: the whole design rests on the belief that was wrong here, so
// without the probe this would have been a separate real-time audio engine.
// Writing it also taught a lesson about probes: the first capture read 1 channel
// (AVAudioEngine kept the previous input's format) and would have reported a false
// result. Capturing through a raw Core Audio IOProc removed that layer.
import AVFoundation
import CoreAudio
import Foundation

let sr = 48000.0, N = 8, len = Int(sr * 3), clickAt = 24000
let freqs = (0..<N).map { 300.0 * Double($0 + 1) }
func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func str(_ d: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel); var v: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr, let v else { return "" }
    return v.takeRetainedValue() as String
}
func findDevice(_ part: String) -> (AudioObjectID, String)? {
    var a = addr(kAudioHardwarePropertyDevices); var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
    for d in ids where str(d, kAudioObjectPropertyName).contains(part) { return (d, str(d, kAudioDevicePropertyDeviceUID)) }
    return nil
}
func setDevice(_ u: AudioUnit, _ d: AudioObjectID) -> OSStatus {
    var d = d
    return AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, 4)
}
guard let (dev, uid) = findDevice("Audio Bridge 16") else { print("no bridge device"); exit(1) }
print("device id \(dev) uid \(uid)")

// Sources: one array per channel.
let sources: [[Float]] = freqs.map { f in
    (0..<len).map { n -> Float in
        if n < clickAt { return 0 }
        if n == clickAt { return 0.9 }
        return Float(0.2 * sin(2 * .pi * f * Double(n) / sr))
    }
}
let tmp = FileManager.default.temporaryDirectory
func write(_ chans: [[Float]], _ name: String) throws -> URL {
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(chans.count))!
    let fmt = chans.count == 1 ? AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
                               : AVAudioFormat(standardFormatWithSampleRate: sr, channelLayout: layout)
    let url = tmp.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    var settings = fmt.settings; settings[AVLinearPCMBitDepthKey] = 32; settings[AVLinearPCMIsFloatKey] = true
    let f = try AVAudioFile(forWriting: url, settings: settings)
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(len))!
    b.frameLength = b.frameCapacity
    for c in chans.indices { chans[c].withUnsafeBufferPointer { b.floatChannelData![c].update(from: $0.baseAddress!, count: len) } }
    try f.write(from: b)
    return url
}
let multi = try write(sources, "probe8.wav")
let monos = try sources.indices.map { try write([sources[$0]], "probe-mono\($0).wav") }

// Capture the device's input side with a raw IOProc: no format conversion, no
// engine state, every channel exactly as the device delivers it.
final class Cap { var ch: [[Float]] = [] }
func capture(seconds: Double, during start: () throws -> Void, after stop: () -> Void) throws -> [[Float]] {
    let cap = Cap(); let q = DispatchQueue(label: "cap")
    var id: AudioDeviceIOProcID?
    let st = AudioDeviceCreateIOProcIDWithBlock(&id, dev, q) { _, input, _, _, _ in
        let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var c = 0
        for b in bufs {
            let nc = Int(b.mNumberChannels); guard nc > 0, let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(b.mDataByteSize) / 4 / nc
            for k in 0..<nc {
                if cap.ch.count <= c { cap.ch.append([]) }
                for i in 0..<frames { cap.ch[c].append(d[i * nc + k]) }
                c += 1
            }
        }
    }
    guard st == noErr, let id else { print("ioproc failed \(st)"); return [] }
    AudioDeviceStart(dev, id)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    try start()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    stop()
    AudioDeviceStop(dev, id); AudioDeviceDestroyIOProcID(dev, id)
    return q.sync { cap.ch }
}
func goertzel(_ x: ArraySlice<Float>, _ f: Double) -> Double {
    let w = 2 * .pi * f / sr, k = 2 * cos(w); var a = 0.0, b = 0.0
    for v in x { let t = Double(v) + k * a - b; b = a; a = t }
    return sqrt(max(0, a * a + b * b - k * a * b)) / Double(max(x.count, 1)) * 2
}
func analyse(_ label: String, _ cap: [[Float]]) {
    print("\n== \(label): captured \(cap.count) ch, \(cap.first?.count ?? 0) samples")
    var clicks: [Int: Int] = [:]
    for (c, x) in cap.enumerated() {
        let peak = x.map { abs($0) }.max() ?? 0
        guard peak > 0.001 else { continue }
        let levels = freqs.map { goertzel(x[...], $0) }
        let on = levels.indices.filter { levels[$0] > levels.max()! * 0.05 }.map { "s\($0 + 1)" }
        if let at = x.firstIndex(where: { abs($0) > peak * 0.8 }) { clicks[c] = at }
        print(String(format: "  out %2d  peak %.3f  sources heard: ", c + 1, peak) + on.joined(separator: " "))
    }
    if clicks.isEmpty { print("  (silence on every channel)") }
    if let lo = clicks.values.min() { print("  click offset between channels: \((clicks.values.max() ?? lo) - lo) samples") }
}

// A: AVPlayer + discrete multichannel file
var pa: AVPlayer? = nil
analyse("A AVPlayer, 8-ch discrete WAV", try capture(seconds: 2.5, during: {
    pa = AVPlayer(url: multi); pa!.audioOutputDeviceUniqueID = uid; pa!.play()
}, after: { pa?.pause(); pa = nil }))

// B: AVPlayer + composition of 8 mono files
let comp = AVMutableComposition()
for u in monos {
    let a = AVURLAsset(url: u)
    let src = a.tracks(withMediaType: .audio)[0]
    let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try t.insertTimeRange(CMTimeRange(start: .zero, duration: a.duration), of: src, at: .zero)
}
var pb: AVPlayer? = nil
analyse("B AVPlayer, composition of 8 mono files", try capture(seconds: 2.5, during: {
    pb = AVPlayer(playerItem: AVPlayerItem(asset: comp)); pb!.audioOutputDeviceUniqueID = uid; pb!.play()
}, after: { pb?.pause(); pb = nil }))

// C: one render callback, source k -> output 15-k (an arbitrary route, on purpose)
let out = AVAudioEngine()
_ = setDevice(out.outputNode.audioUnit!, dev)
let hw = out.outputNode.outputFormat(forBus: 0)
print("\nengine output format: \(hw.channelCount) ch @ \(hw.sampleRate)")
let fmt16 = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate,
                          channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hw.channelCount)!)
var pos = 0
let node = AVAudioSourceNode(format: fmt16) { _, _, frames, abl in
    let bufs = UnsafeMutableAudioBufferListPointer(abl)
    for b in bufs { if let m = b.mData { memset(m, 0, Int(b.mDataByteSize)) } }
    for k in 0..<N {
        guard let d = bufs[bufs.count - 1 - k].mData?.assumingMemoryBound(to: Float.self) else { continue }
        for i in 0..<Int(frames) where pos + i < len { d[i] = sources[k][pos + i] }
    }
    pos += Int(frames)
    return noErr
}
out.attach(node)
out.connect(node, to: out.outputNode, format: fmt16)
analyse("C AVAudioEngine, one callback, source k -> output \(hw.channelCount)-k", try capture(seconds: 2.5, during: {
    pos = 0; try out.start()
}, after: { out.stop() }))
