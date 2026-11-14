// PROBE: does an audio device's sample clock keep time with the host clock?
//
// Idea at risk: "the host clock and the sound device agree closely enough that
// nothing needs correcting." AVPlayer video follows the host clock; a sound output
// runs on the DEVICE's own crystal. If the two differ by d ppm (parts per million),
// sound could gain d microseconds per second on the picture.
//
// FALSIFIED BY: drift over 1 ppm, since an "until moved on" work or an 8 h show
// (T18) would then build up an error that's measurable.
//
// Plays SILENCE (zeroed buffers) to the default output, opens no window, and fits
// a line through (host seconds, sample count) by LEAST SQUARES: the slope is the
// device's real sample rate. A fit uses every reading, so timestamp jitter averages
// out, which is how 90 s can resolve a fraction of a ppm.
//
//   swiftc -O audio-clock-probe.swift -o probe && ./probe 90
//
// WHAT IT TAUGHT (2026-11-05, MacBook Pro speakers, 90 s): FALSIFIED. +8.67 ppm, and
// steady (every 15 s window read 8.67-8.68). That's a frame at 30 fps every 64 min,
// or about 250 ms over 8 h.
// Limits: this measures the Mac's own speakers, not an external interface, and a
// device's rate is a property of that device. So +8.67 ppm is a reading for one
// device and carries to no other: an external converter runs on its own crystal
// and could be faster, slower or steadier. That is reasoning from where the
// crystal sits, NOT measured here — no external device has been read yet.
// It also shows the clocks differ, not that sound drifts:
// AVPlayer might correct for it. That needs a test of what actually arrives, on real
// hardware (Tests/PlayerCoreTests/AudioLoopbackTests.swift, target T23). Not yet run.
import AVFoundation
import Foundation

let seconds = Int(CommandLine.arguments.dropFirst().first ?? "90") ?? 90
let engine = AVAudioEngine()
let out = engine.outputNode.outputFormat(forBus: 0)
print("output: \(Int(out.channelCount)) ch @ \(out.sampleRate) Hz")

let silence = AVAudioSourceNode { isSilence, _, _, abl in
    isSilence.pointee = true
    for b in UnsafeMutableAudioBufferListPointer(abl) {
        if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
    }
    return noErr
}
engine.attach(silence)
engine.connect(silence, to: engine.mainMixerNode, format: nil)
try engine.start()

var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
func hostSeconds(_ h: UInt64) -> Double { Double(h) * Double(tb.numer) / Double(tb.denom) / 1e9 }

var points: [(h: Double, s: Double)] = []
Thread.sleep(forTimeInterval: 2)            // let the HAL's timing filter settle
for i in 0..<(seconds * 4) {
    Thread.sleep(forTimeInterval: 0.25)
    if let t = engine.outputNode.lastRenderTime, t.isHostTimeValid, t.isSampleTimeValid {
        points.append((hostSeconds(t.hostTime), Double(t.sampleTime)))
    }
    if i % 60 == 59, points.count > 8 { report(points) }
}
engine.stop()
report(points)

func report(_ p: [(h: Double, s: Double)]) {
    let n = Double(p.count)
    let mh = p.map(\.h).reduce(0, +) / n, ms = p.map(\.s).reduce(0, +) / n
    let num = p.map { ($0.h - mh) * ($0.s - ms) }.reduce(0, +)
    let den = p.map { ($0.h - mh) * ($0.h - mh) }.reduce(0, +)
    let rate = num / den
    let ppm = (rate / out.sampleRate - 1) * 1e6
    var resid = 0.0
    for q in p {
        let e: Double = abs((q.s - ms) - rate * (q.h - mh))
        resid = max(resid, e / out.sampleRate * 1000)
    }
    let frameEvery: Double = (1.0 / 30.0) / (abs(ppm) * 1e-6) / 60.0
    print(String(format: "%5.0f s  rate %.4f Hz  drift %+.2f ppm  worst residual %.3f ms  one 30 fps frame every %.0f min",
                 p.last!.h - p.first!.h, rate, ppm, resid, frameEvery))
}
