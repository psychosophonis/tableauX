// PROBE: "a ring of overlapping stereo pairs can be summed into one bake"
// (docs/architecture.md § v6 › Pairs may overlap, and may wrap; T25, T26).
//
// From the first run on a hardware interface (2026-11-12): a work of six stereo pairs wanted
// the pairs staggered — 1-2, 2-3, 3-4, 4-5, 5-6, 6-1 — each file spread between
// two adjacent speakers, the last wrapping to the first. Every output then
// carries TWO sources: the right channel of one file and the left of the next.
// § v5 refused that outright, so before changing the routing rules, this asks
// whether the arithmetic underneath them survives.
//
// IDEA AT RISK: file k on outputs (k, k+1), wrapping, summed at equal level with
// ONE downward gain over the whole mix, puts exactly the two channels it should
// on each output, stays inside full scale, and is still usable.
//
// FALSIFIED BY any of:
//  1 energy from a file on an output it was not routed to, above −60 dB (T25);
//  2 any sample over full scale after the gain (T26);
//  3 a gain so deep that the ring is pointless — the work would be unusable.
//
// It tests the PRINCIPLE, not the app: the mixing rule is written out here in a
// few lines rather than called from PlayerCore, so the result holds for any
// later implementation. Nothing here touches a sound device; the bake's own
// file writing and playback were probed separately (audio-bake-pipeline-probe).
//
// TWO RINGS, because the failures pull in opposite directions:
//  B (routing): all twelve channels carry their own tone, so each output can be
//    checked for exactly the two it should have and the ten it shouldn't.
//  A (worst case for level): adjacent files SHARE a tone, so the two sources on
//    each output sum perfectly IN PHASE, reaching the arithmetic sum of their
//    amplitudes — the loudest two sources can be. Kept as the stated upper bound
//    even though the run showed ring B reaches the same peak (see WHAT IT TAUGHT
//    at the end): A proves the bound holds, B showed it is not a corner case.
//
// Build and run:
//   swiftc -O proofs/stagger-ring-probe.swift -o .build/stagger-ring-probe && .build/stagger-ring-probe
//
// WHAT IT TAUGHT (2026-11-12): see the end of this file.
import Foundation

let sr = 48000.0
let seconds = 2.0
let frames = Int(sr * seconds)
let N = 6                       // outputs, and stereo sources, in the ring
let level: Float = 0.7          // per channel: a hot master, so a sum must clip

// Tones at exact multiples of 0.5 Hz, which is one cycle per 2 s window.
//
// Deliberate, and the one piece of signal theory this probe rests on: a DFT bin
// measured at a frequency with a WHOLE NUMBER OF CYCLES in the window sees every
// other such tone as exactly zero (they are ORTHOGONAL over that window). Choose
// the frequencies carelessly and each tone SPECTRALLY LEAKS into its neighbours'
// bins, which would read as crosstalk and fail the −60 dB test for a reason that
// has nothing to do with the routing. The alternative is a window function
// (Hann, say) to suppress leakage; orthogonal tones make it unnecessary.
let tones: [Double] = [311, 373, 419, 467, 523, 587, 641, 701, 757, 811, 877, 937]

func sine(_ f: Double, amplitude: Float = level) -> [Float] {
    (0..<frames).map { amplitude * Float(sin(2 * .pi * f * Double($0) / sr)) }
}

/// Amplitude of one tone in a signal, by MATCHED FILTERING: correlate with the
/// complex exponential at that frequency. For a sine sitting exactly on the bin
/// this returns its amplitude, and 0 for any other orthogonal tone — so it reads
/// "how much of file k's channel is on this output" directly, in the units the
/// −60 dB test is stated in.
func amplitude(of f: Double, in x: [Float]) -> Double {
    var re = 0.0, im = 0.0
    for (n, v) in x.enumerated() {
        let phase = 2 * .pi * f * Double(n) / sr
        re += Double(v) * cos(phase)
        im -= Double(v) * sin(phase)
    }
    return 2 * (re * re + im * im).squareRoot() / Double(x.count)
}

/// One source's channel sent to one output: the bake's `Feed`, cut down to what
/// a ring needs (no per-feed gain, no multi-channel averaging).
struct Feed { let output: Int, source: Int, channel: Int }

/// The ring Mat asked for: file k to outputs (k, k+1), the last wrapping to the
/// first. Left goes to the lower output of the pair, right to the upper.
func ringFeeds(first: Int) -> [Feed] {
    (0..<N).flatMap { k -> [Feed] in
        let low = first + k
        let high = first + (k + 1) % N          // the wrap: file N-1's right returns to `first`
        return [Feed(output: low, source: k, channel: 0), Feed(output: high, source: k, channel: 1)]
    }
}

/// The mixing rule under test, written out plainly: accumulate every feed into
/// its output, measure the peak, then apply ONE gain to the whole mix, downward
/// only. Same rule as AudioBake.bake(preventClipping:).
///
/// Why one gain over everything rather than per output, or a limiter: the ring's
/// point is the image between adjacent speakers, and that image is set by the
/// RATIO of levels across outputs. A per-output gain, or a limiter acting moment
/// by moment, would change those ratios and move the image while the work plays.
/// A single scalar cannot: it is the one correction that is inaudible except as
/// overall loudness.
func mix(_ sources: [[[Float]]], _ feeds: [Feed], outputs: Int) -> (out: [[Float]], peak: Float, gain: Float) {
    var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: outputs)
    for f in feeds {
        let channel = sources[f.source][f.channel]
        for n in 0..<frames { out[f.output - 1][n] += channel[n] }
    }
    let peak = out.flatMap { $0 }.map(abs).max() ?? 0
    let gain: Float = peak > 1 ? 1 / peak : 1
    if gain != 1 { for o in 0..<outputs { for n in 0..<frames { out[o][n] *= gain } } }
    return (out, peak, gain)
}

func dB(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }

var failures: [String] = []

// ── Ring B: routing. Twelve distinct tones, one per channel. ──────────────────
// Each output must hold exactly two of them: the right channel of the file
// before it in the ring, and the left channel of its own file.
let distinct = (0..<N).map { k in [sine(tones[2 * k]), sine(tones[2 * k + 1])] }
let feeds = ringFeeds(first: 1)
let (ringB, peakB, gainB) = mix(distinct, feeds, outputs: N)

print("Ring B — routing, twelve distinct tones, pairs 1-2, 2-3, 3-4, 4-5, 5-6, 6-1")
for o in 1...N {
    let expected = Set(feeds.filter { $0.output == o }.map { 2 * $0.source + $0.channel })
    var worstStray = 0.0, strayName = ""
    var quietestWanted = Double.infinity
    for (i, tone) in tones.enumerated() {
        let a = amplitude(of: tone, in: ringB[o - 1])
        if expected.contains(i) {
            quietestWanted = min(quietestWanted, a)
        } else if a > worstStray {
            worstStray = a; strayName = "file \(i / 2 + 1)'s \(i % 2 == 0 ? "left" : "right")"
        }
    }
    // Both wanted channels are scaled by the same gain as everything else, so
    // they are compared with the level they were given, times that gain.
    let wantedRef = Double(level * gainB)
    let strayRelative = worstStray / wantedRef
    let ok = quietestWanted > wantedRef * 0.99 && strayRelative < 0.001      // −60 dB
    print(String(format: "  output %d: wanted channels at %.3f (expected %.3f), worst stray %@ at %.1f dB  %@",
                 o, quietestWanted, wantedRef, strayName.isEmpty ? "none" : strayName as NSString,
                 dB(strayRelative), ok ? "OK" : "FAILED"))
    if !ok { failures.append("output \(o) routing") }
}
print(String(format: "  peak before gain %.3f, gain %.2f (%.1f dB)", peakB, gainB, dB(Double(gainB))))

// ── Ring A: level, worst case. Adjacent files share a tone. ──────────────────
// File k is (left: tone k, right: tone k+1), so the two sources meeting on an
// output are the same tone at the same phase: they add to exactly twice the
// amplitude. Nothing a real work could do is louder than this.
let shared = (0..<N).map { k in [sine(tones[k]), sine(tones[(k + 1) % N])] }
let (ringA, peakA, gainA) = mix(shared, feeds, outputs: N)
let clipped = ringA.flatMap { $0 }.map(abs).max() ?? 0

print("\nRing A — worst case for level, adjacent files sharing a tone (in phase)")
print(String(format: "  peak before gain %.3f (two sources at %.2f, perfectly in phase)", peakA, level))
print(String(format: "  gain %.3f = %.1f dB applied to the whole mix", gainA, dB(Double(gainA))))
print(String(format: "  peak after gain %.6f  %@", clipped, clipped <= 1.0 ? "inside full scale" : "OVER FULL SCALE"))
if clipped > 1.0 { failures.append("ring A clips after the gain") }
// Claim 3: is it still usable? −6 dB is the arithmetic floor for two in-phase
// sources at equal level; anything deeper than about −12 dB would mean the ring
// costs more than a person would accept without being told.
if dB(Double(gainA)) < -12 { failures.append("ring A gain deeper than −12 dB: unusable") }

print("\n" + (failures.isEmpty
    ? "SURVIVED: each output carried exactly its two channels, strays below −60 dB, "
      + "no clipping after one downward gain."
    : "FALSIFIED: " + failures.joined(separator: "; ")))
exit(failures.isEmpty ? 0 : 1)

// WHAT IT TAUGHT (2026-11-12, run on this MacBook):
//
// The idea survived both rings: every output carried exactly its two channels,
// the wrap put file 6's right channel back on output 1, strays read −176 dB
// (floating-point zero), and one downward gain brought the peak to exactly 1.0.
//
// It also killed a prediction I had written down before running it, which is the
// more useful result. I expected ring B (twelve independent tones) to peak near
// 0.99 and need NO gain, on the reasoning that uncorrelated sources rarely peak
// together — so the level cost would depend on how alike the neighbouring files
// were. Both rings peaked at exactly 1.400 and both needed −2.9 dB. Two sine
// tones of ANY two frequencies drift through every phase relationship, so over a
// two-second window they do align, and the peak lands on the arithmetic sum
// whether the sources are correlated or not.
//
// What that means for § v6, and it is better news than my guess: the level cost
// of a ring is PREDICTABLE from the source level and the number of sources
// sharing an output, not from the material. Measured here: two sources at 0.7
// cost 2.9 dB. The bounds are arithmetic rather than measured — two sources at
// full scale sum to 2.0, so a pair can never cost more than 6 dB, and sources
// quiet enough that their sum stays under 1.0 cost nothing. Correlation changes the
// loudness that survives the gain (identical in-phase sources come out 3 dB
// louder in RMS than independent ones at the same peak), not the gain itself.
// So "your ring will be a few dB quieter, and how much depends on how hot your
// files are" is a thing the app can honestly tell a person in advance.
//
// What this probe CANNOT say, by construction: real material is transient and
// broadband, not sustained sine tones, so its peaks are a property of the work.
// And in-memory summing can't leak between outputs, so the −60 dB crosstalk claim
// was never at risk here. The ways crosstalk could really appear — a channel
// layout misread, a reader's interleaving, a device's own mixing — live in the
// parts deliberately left out, and are covered by audio-bake-pipeline-probe.swift
// on a real device.
