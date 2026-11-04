import Foundation

// [claude] v5: multichannel sound (docs/architecture.md § v5). Like the rest of
// PlayerCore these are PURE DECISIONS: given what a file contains and where a
// person assigned it, which output gets what. Reading files and playing them
// happen elsewhere (AudioBake, the app), so every rule here is testable with
// made-up facts and no audio hardware.

/// What to take from a source. `auto` applies § A stereo file meant for one
/// speaker; the rest are a person overruling it, which must always be possible
/// because the automatic reading can be wrong.
public enum AudioTake: String, Codable, CaseIterable {
    case auto, pair, sum, left, right
}

/// One source sent to one output of this Mac's interface.
///
/// Exactly one of `file` and `screen` is set. The usual Swift for "one of these"
/// is a SUM TYPE (an enum with associated values), which makes the illegal state
/// impossible to write down. Two plain optionals allow it, and that's a deliberate
/// trade: the show file stays readable and fixable by hand,
/// `{"file":"Smith/audio/a_3.wav","output":3,"take":"auto"}`, as every other part
/// of it is. If a hand-edited file sets both, the file wins.
public struct AudioRoute: Codable, Equatable {
    /// As a panel stores it: relative to the media folder, or a full path.
    public var file: String?
    /// This Mac's display index (0-based): that screen's video provides the sound.
    public var screen: Int?
    /// The first output it goes to, from 1; 0 = off. Outputs are numbered per Mac (Mat).
    public var output: Int
    public var take: AudioTake

    public init(file: String? = nil, screen: Int? = nil, output: Int, take: AudioTake = .auto) {
        self.file = file; self.screen = screen; self.output = output; self.take = take
    }
}

/// How the two channels of a stereo file relate.
public enum StereoKind: String, Codable, Equatable {
    case different, dual, leftOnly, rightOnly, silent
}

/// What a source contains, measured by `AudioBake.analyse`.
public struct AudioFacts: Codable, Equatable {
    public var channels: Int          // 0 = it has no sound
    public var sampleRate: Double
    public var duration: Double
    public var stereo: StereoKind     // meaningful only for 2 channels

    public init(channels: Int, sampleRate: Double = 48000, duration: Double = 0, stereo: StereoKind = .different) {
        self.channels = channels; self.sampleRate = sampleRate; self.duration = duration; self.stereo = stereo
    }
}

public enum AudioRouting {
    /// One output of the bake: the average of these channels of this source.
    public struct Feed: Equatable {
        public var output: Int        // from 1
        public var source: Int        // index into the routes
        public var channels: [Int]    // from 0; more than one = summed at equal level
        public var gain: Double       // 1 on a full bake; a fold-down's pan otherwise

        public init(output: Int, source: Int, channels: [Int], gain: Double = 1) {
            self.output = output; self.source = source; self.channels = channels; self.gain = gain
        }
    }

    /// One Mac's sound, going into a fold-down. `sources` is how many routes the plan
    /// was made from, which places the next Mac's sources after these ones.
    public struct FoldPart {
        public var plan: Plan
        public var sources: Int
        public var pan: (Int) -> Double

        public init(plan: Plan, sources: Int, pan: @escaping (Int) -> Double) {
            self.plan = plan; self.sources = sources; self.pan = pan
        }
    }

    /// A pan position (−1 left to +1 right) as a gain for each side.
    ///
    /// An EQUAL-POWER PAN LAW: left = cos θ, right = sin θ. Since cos² + sin² = 1, the
    /// total power is the same at every position. The obvious linear crossfade (each
    /// side at half at the centre) makes a sound 3 dB quieter in the middle, because
    /// perceived level follows power, not amplitude. That would mislead here: a centre
    /// speaker would seem quiet against the sides, and balance is what this checks.
    public static func panGains(_ pan: Double) -> (left: Double, right: Double) {
        let theta = (min(max(pan, -1), 1) + 1) * .pi / 4
        return (cos(theta), sin(theta))
    }

    /// Several Macs' plans mixed down to outputs 1 and 2 (§ Stereo fold-down).
    ///
    /// It works from the plans' feeds rather than their routes, so every decision
    /// already made and shown to the person, such as a dual-mono file taking one
    /// speaker, holds in the fold-down too. It folds what the array would play, which
    /// is the point of checking it.
    public static func fold(_ parts: [FoldPart]) -> Plan {
        var out = Plan()
        var offset = 0
        for part in parts {
            for feed in part.plan.feeds {
                let (left, right) = panGains(part.pan(feed.output))
                // A hard-panned speaker's other side is about 6e-17, not 0. Skipping it
                // saves a pointless mix pass and keeps the plan readable in tests.
                if left > 1e-6 { out.feeds.append(Feed(output: 1, source: offset + feed.source, channels: feed.channels, gain: left)) }
                if right > 1e-6 { out.feeds.append(Feed(output: 2, source: offset + feed.source, channels: feed.channels, gain: right)) }
            }
            if !part.plan.feeds.isEmpty {
                out.sampleRate = max(out.sampleRate, part.plan.sampleRate)
                out.length = max(out.length, part.plan.length)
            }
            out.problems += part.plan.problems
            out.warnings += part.plan.warnings
            offset += part.sources
        }
        out.outputs = out.feeds.isEmpty ? 0 : 2
        return out
    }

    public struct Plan: Equatable {
        public var feeds: [Feed] = []
        /// Channels the bake needs: at least 2 whenever there is any sound.
        /// A precaution, not a measured fault: a one-channel file means "mono" to
        /// AVFoundation, not "output 1", and it might spread that to several
        /// speakers. Nobody has tested a 1-channel bake; the 2-channel one was
        /// tested and stays on output 1 (`AudioLoopbackTests`), so there's no need to.
        public var outputs = 0
        public var sampleRate = 0.0
        public var length = 0.0
        public var lines: [String] = []       // per route, what it was read as
        public var problems: [String] = []    // stop Present
        public var warnings: [String] = []
        /// Some route's source hasn't been measured yet, so this plan can't be baked.
        public var incomplete = false
    }

    /// The thresholds of § A stereo file meant for one speaker.
    ///
    /// These are amplitude ratios, written here as linear numbers and in DECIBELS:
    /// dB = 20·log10(ratio), so every −20 dB is a tenth of the level. Decibels are
    /// the natural unit for this because hearing and recording levels both span
    /// many orders of magnitude, and ratios become differences.
    ///
    /// Each limit is RELATIVE to the signal, not absolute, so a quiet file is judged
    /// the same as a loud one. The exception is the silence floor: a ratio of two
    /// near-zero numbers means nothing, so it needs an absolute level (dBFS, decibels
    /// below digital full scale).
    static let dualLimit = 0.01          // L−R at or below −40 dB of the signal
    static let oneSidedLimit = 0.001     // a channel at or below −60 dB of the other
    static let silenceFloor = 0.0001     // both below −80 dBFS

    /// Reads a stereo source from three RMS levels (linear, 1 = full scale).
    ///
    /// This is a THRESHOLD CLASSIFIER, so it has two ways to be wrong, and they
    /// aren't equal. A FALSE NEGATIVE (dual mono read as stereo) plays one sound on
    /// two speakers. A FALSE POSITIVE (narrow stereo read as dual) silently throws a
    /// channel away. The limit is the trade between them, and it rests on measured
    /// data (`proofs/audio-decode-probe.swift`): dual mono read −44 dB or lower
    /// through common encoders, and the closest real stereo read −39 dB. That margin
    /// is thin, and pure noise through ffmpeg's AAC escapes it entirely (−13 dB), so
    /// no threshold could be right every time. That's why this only sets a default
    /// that a person can see and overrule, and why it isn't made any cleverer.
    public static func classify(left: Double, right: Double, difference: Double) -> StereoKind {
        let loudest = max(left, right)
        if loudest < silenceFloor { return .silent }
        if right <= left * oneSidedLimit { return .leftOnly }
        if left <= right * oneSidedLimit { return .rightOnly }
        return difference <= loudest * dualLimit ? .dual : .different
    }

    /// Decides what every output gets, and says why, per route.
    ///
    /// A TWO-PASS ALLOCATION, for the reason a two-pass assembler has two passes: a
    /// decision depends on something later in the list. A stereo file spreads to N+1
    /// only if nothing wants N+1, and the file that wants it may not have been
    /// reached yet. So the first pass records every claim that's already fixed (each
    /// route's first output, and any fixed span), and only the second lets stereo
    /// spread. Done in one pass, the answer would depend on the order routes happen
    /// to be stored in. Done in two, an array of stereo files numbered 1, 2, 3 comes
    /// out one speaker each however they're listed.
    public static func plan(routes: [AudioRoute], facts: [AudioFacts?]) -> Plan {
        var plan = Plan()
        plan.lines = Array(repeating: "", count: routes.count)
        var feedsOf = Array(repeating: [Feed](), count: routes.count)
        var pending: [Int] = []                             // real stereo, set to automatic
        var taken = Set(routes.map(\.output))

        func one(_ i: Int, _ channels: [Int], _ why: String) {
            feedsOf[i] = [Feed(output: routes[i].output, source: i, channels: channels)]
            plan.lines[i] = "Output \(routes[i].output): \(why)"
        }
        func span(_ i: Int, count: Int, _ why: String) {
            let first = routes[i].output
            feedsOf[i] = (0..<count).map { Feed(output: first + $0, source: i, channels: [$0]) }
            taken.formUnion(first..<first + count)
            plan.lines[i] = "Outputs \(first)–\(first + count - 1): \(why)"
        }

        for (i, r) in routes.enumerated() {
            // Output 0 is "off". The route stays, so a rescan doesn't see a new
            // file and turn it back on; that's how a folder's file is silenced.
            guard r.output >= 1 else {
                plan.lines[i] = "Off"
                continue
            }
            guard let f = i < facts.count ? facts[i] : nil else {
                plan.incomplete = true
                plan.lines[i] = "Output \(r.output): reading the file…"
                continue
            }
            guard f.channels > 0 else {
                plan.lines[i] = "Output \(r.output): no sound in this file"
                plan.warnings.append("\(name(r)) has no sound.")
                continue
            }
            let c = f.channels
            switch r.take {
            case .sum: one(i, Array(0..<c), c == 1 ? "mono" : "\(c) channels summed, as you set")
            case .left: one(i, [0], c == 1 ? "mono" : "left channel, as you set")
            case .right: one(i, [min(1, c - 1)], c == 1 ? "mono" : "right channel, as you set")
            case .pair:
                if c == 1 { one(i, [0], "mono") } else { span(i, count: 2, "pair, as you set") }
            case .auto:
                switch (c, f.stereo) {
                case (1, _): one(i, [0], "mono")
                case (2, .dual): one(i, [0], "both channels are the same, so one speaker")
                case (2, .leftOnly): one(i, [0], "right channel is silent, so one speaker")
                case (2, .rightOnly): one(i, [1], "left channel is silent, so one speaker")
                case (2, .silent):
                    one(i, [0], "silent")
                    plan.warnings.append("\(name(r)) is silent.")
                case (2, .different): pending.append(i)
                default: span(i, count: c, "\(c) channels in order")
                }
            }
        }

        // Second pass: real stereo, lowest output first, so the result doesn't
        // depend on the order the routes happen to be stored in.
        //
        // The last file of an array has a free output after it, but it's still
        // one speaker of that array. So a file directly after one summed here is
        // summed too, or a student's last speaker would leak onto the next output.
        var summed: Set<Int> = []
        for i in pending.sorted(by: { routes[$0].output < routes[$1].output }) {
            let output = routes[i].output, next = output + 1
            if taken.contains(next) {
                one(i, [0, 1], "stereo summed to one speaker, because output \(next) is taken")
                summed.insert(output)
            } else if summed.contains(output - 1) {
                one(i, [0, 1], "stereo summed to one speaker, as part of the array before it")
                summed.insert(output)
            } else {
                span(i, count: 2, "stereo")
            }
        }

        // Two sources on one output is a mistake to show, not something to mix
        // silently: mixing is what a person would have asked for by hand.
        var owner: [Int: Int] = [:]
        for feeds in feedsOf {
            for feed in feeds {
                if let other = owner[feed.output], other != feed.source {
                    plan.problems.append("Output \(feed.output) has two sources: \(name(routes[other])) and \(name(routes[feed.source])).")
                }
                owner[feed.output] = feed.source
            }
        }

        plan.feeds = feedsOf.flatMap { $0 }.sorted { $0.output < $1.output }
        if let highest = plan.feeds.map(\.output).max() { plan.outputs = max(highest, 2) }
        let used = routes.indices.compactMap { i -> AudioFacts? in
            guard !feedsOf[i].isEmpty, i < facts.count else { return nil }
            return facts[i]
        }
        plan.sampleRate = used.map(\.sampleRate).max() ?? 0
        plan.length = used.map(\.duration).max() ?? 0
        if let short = used.map(\.duration).min(), plan.length - short > 1.0 / 30 {
            plan.warnings.append(String(format: "Sound sources differ in length: %.2f s to %.2f s. Shorter ones go silent early, or loop if this work loops shorter screens.", short, plan.length))
        }
        return plan
    }

    /// How a route is named to a person.
    public static func name(_ r: AudioRoute) -> String {
        if let f = r.file { return (f as NSString).lastPathComponent }
        return r.screen.map { "Screen \($0 + 1)'s video" } ?? "A source"
    }
}

// MARK: - Finding sound in a work's folder (§ Getting sound in)

public enum AudioScan {
    public static let folderName = "audio"
    public static let extensions: Set<String> = ["wav", "aif", "aiff", "m4a", "mp3"]

    /// The sound files in a listing, in natural name order (see FolderScan.videos).
    public static func sounds(_ names: [String]) -> [String] {
        names.filter {
            !($0 as NSString).lastPathComponent.hasPrefix(".")
                && extensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Which files of a listing of `audio/` belong to this Mac (Mat: per-Mac
    /// subfolders). `names` are relative to `audio/`: "a_1.wav", "Gallery 2/b.wav".
    /// A Mac with its own subfolder, by computer name or label, uses only that;
    /// otherwise the loose files. Another Mac's subfolder is never used.
    public static func own(_ names: [String], machine: String, label: String? = nil) -> [String] {
        let mine = [machine, label].compactMap { $0 }.map { $0 + "/" }
        let inSubfolder = names.filter { n in mine.contains { n.hasPrefix($0) } }
        return sounds(inSubfolder.isEmpty ? names.filter { !$0.contains("/") } : inSubfolder)
    }

    /// The files in a Mac's own subfolder of `audio/`. For a Mac composed ahead, listed
    /// from this Mac's library: unlike `own`, it never falls back to the loose files,
    /// because those are this Mac's, and would otherwise be routed on two Macs at once.
    public static func subfolderOnly(_ names: [String], machine: String, label: String? = nil) -> [String] {
        let theirs = [machine, label].compactMap { $0 }.map { $0 + "/" }
        return names.filter { n in theirs.contains { n.hasPrefix($0) } }
    }

    /// The routes for one Mac and one work, with any new files added. Routes
    /// already there are never moved or removed (a person may have set them), the
    /// same promise a rescan makes about screens. A new file named "_N" goes to
    /// output N if it is free; every other new file takes the lowest free output,
    /// which is FIRST-FIT ALLOCATION, as simple memory allocators use.
    ///
    /// The function is IDEMPOTENT: given its own result and the same folder, it
    /// returns that result unchanged. Rescans run every few seconds and any change
    /// to the show triggers an autosave and a share with the players, so a merge that
    /// wasn't idempotent would keep the whole show churning with nothing changed.
    /// nil if there is nothing to route.
    public static func routes(existing: [AudioRoute]?, folder: String, names: [String]) -> [AudioRoute]? {
        var out = existing ?? []
        let known = Set(out.compactMap(\.file))
        var taken = Set(out.map(\.output))
        let new = sounds(names).filter { !known.contains(path(folder, $0)) }
        func lowestFree() -> Int {
            var n = 1
            while taken.contains(n) { n += 1 }
            return n
        }
        // Numbered first, so a free slot isn't handed to an unnumbered file
        // and then found to be the number another file asked for.
        for name in new {
            guard let n = FolderScan.screenNumber((name as NSString).lastPathComponent), !taken.contains(n) else { continue }
            taken.insert(n)
            out.append(AudioRoute(file: path(folder, name), output: n))
        }
        let placed = Set(out.compactMap(\.file))
        for name in new where !placed.contains(path(folder, name)) {
            let n = lowestFree()
            taken.insert(n)
            out.append(AudioRoute(file: path(folder, name), output: n))
        }
        return out.isEmpty ? nil : out
    }

    /// "Smith/audio/a_1.wav": how a route stores a file, as a panel does.
    public static func path(_ folder: String, _ name: String) -> String { "\(folder)/\(folderName)/\(name)" }
}

// MARK: - Which device plays it (§ Output device)

public enum AudioOutputs {
    public struct Device: Equatable {
        public var uid: String
        public var name: String
        public var outputs: Int
        public var isVirtual: Bool

        public init(uid: String, name: String, outputs: Int, isVirtual: Bool = false) {
            self.uid = uid; self.name = name; self.outputs = outputs; self.isVirtual = isVirtual
        }
    }

    /// The device to use, or nil if none can be chosen safely.
    ///
    /// A PRECEDENCE CHAIN that FAILS CLOSED: each rule is tried in order, and if the
    /// answer is still ambiguous at the end it refuses rather than picks. Failing
    /// closed fits an installation because the two failures cost very different
    /// amounts: a refusal shows up at setup with a message, whereas a wrong guess
    /// shows up as a work's sound coming out of the wrong room during a show.
    ///
    /// A device set by hand wins even if it has too few outputs, so the message can
    /// name the device a person chose instead of quietly using another. Then the
    /// Mac's default output if it can carry the work, then the only real interface
    /// that can. Virtual devices are skipped when guessing, because they make no
    /// sound of their own; one can still be chosen by hand.
    public static func pick(devices: [Device], chosen: String?, defaultUID: String?, needed: Int) -> Device? {
        if let chosen, let d = devices.first(where: { $0.uid == chosen }) { return d }
        if let d = devices.first(where: { $0.uid == defaultUID }), d.outputs >= needed { return d }
        let fit = devices.filter { !$0.isVirtual && $0.outputs >= needed }
        return fit.count == 1 ? fit[0] : nil
    }
}
