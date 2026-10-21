import Foundation

// [claude] v4: playlists of works (docs/architecture.md § v4). Everything here
// is a PURE FUNCTION of its inputs: no files are read, no clocks consulted.
// The app lists folders and measures files; this decides what that means.
// Keeping the decisions pure is what makes them testable without a disk or a
// network, and is what lets every Mac reach the SAME answer from the same
// inputs, which the playlist's timing depends on (§ v4 › Timing).

/// How many times a work plays before the playlist moves on.
public enum Repeat: Equatable {
    case times(Int)      // 1 = once
    case untilNext       // a single piece on a loop: only a person moves it on

    public static let once = Repeat.times(1)
}

/// Stored as a number (how many times) or the word "untilNext", so a show
/// file stays readable by hand: `"repeat": 1`, `"repeat": "untilNext"`.
extension Repeat: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            guard n >= 1 else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "repeat must be ≥ 1") }
            self = .times(n)
        } else if try c.decode(String.self) == "untilNext" {
            self = .untilNext
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "repeat must be a number or \"untilNext\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .times(let n): try c.encode(n)
        case .untilNext: try c.encode("untilNext")
        }
    }
}

/// What screens whose file is shorter than the work do (Mat: an option).
public enum Shorter: String, Codable, Equatable {
    case black          // go black when done (default: nothing repeats that wasn't meant to)
    case loop           // repeat until the longest file ends
}

/// One student's piece: a file per screen, on each Mac (§ v4 › Model).
public struct Work: Codable, Equatable {
    public var name: String                       // = the folder name on every Mac
    public var screens: [String: [PanelConfig]]   // Mac name → its displays' panels
    public var `repeat`: Repeat
    public var shorter: Shorter

    public init(name: String, screens: [String: [PanelConfig]] = [:], repeat: Repeat = .once, shorter: Shorter = .black) {
        self.name = name; self.screens = screens; self.repeat = `repeat`; self.shorter = shorter
    }
}

public struct PlaylistSettings: Codable, Equatable {
    public var gap: Double          // seconds of black between works
    public var loop: Bool           // back to the first work after the last
    public static let standard = PlaylistSettings(gap: 3, loop: true)
    public init(gap: Double, loop: Bool) { self.gap = gap; self.loop = loop }
}

// MARK: - Folder scan (§ v4 › Getting works in; T14)

public enum FolderScan {
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// The video files in a folder listing, in screen order.
    ///
    /// NATURAL SORT: names compared the way Finder shows them, with runs of
    /// digits compared as numbers, so "2.mp4" comes before "10.mp4". A plain
    /// string sort would put "10" first (the character "1" < "2"), and a
    /// student who numbered their screens 1–12 would find screen 10 on
    /// display 2. Hidden files (".DS_Store", "._clip.mov" from a copy off a
    /// FAT drive) are skipped: they're never a screen.
    public static func videos(_ names: [String]) -> [String] {
        names.filter { !$0.hasPrefix(".") && videoExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
             .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// One Mac's panels for one work: its videos in order onto its displays,
    /// audio off (Mat's default), the rest black. Files beyond the Mac's
    /// display count are returned as `leftOver`, for setup's warning.
    /// `folder` prefixes each file, giving a path relative to the media folder.
    public static func assign(folder: String, files: [String], displays: Int) -> (panels: [PanelConfig], leftOver: [String]) {
        let ordered = videos(files)
        let used = ordered.prefix(displays)
        var panels = used.map { PanelConfig(file: "\(folder)/\($0)", audio: false, scaling: .fit) }
        while panels.count < displays { panels.append(PanelConfig()) }
        return (panels, Array(ordered.dropFirst(displays)))
    }

    /// [claude] A work's panels grown to `displays`: the panels already set are
    /// kept exactly (a hand-set file, or a display left black on purpose), and
    /// the new displays take the folder's videos that no panel uses yet, in
    /// name order (Mat, 2026-10-21: a display plugged in after the scan should
    /// pick up the left-over files). Returns what is still unused.
    ///
    /// This is APPEND-ONLY on purpose: the rescan rule is that a person's
    /// setup is never disturbed, and the only screens nobody has set are the
    /// ones beyond the stored panels. For the same reason it stops when the
    /// files run out instead of padding with black: a black display that was
    /// never stored is still "unset", so a file added to the folder later
    /// fills it on the next scan. (Setup pads with black when it reads.)
    public static func fill(_ panels: [PanelConfig], folder: String, files: [String], displays: Int) -> (panels: [PanelConfig], leftOver: [String]) {
        let used = Set(panels.compactMap(\.file))
        var unused = videos(files).filter { !used.contains("\(folder)/\($0)") }
        var out = panels
        while out.count < displays, !unused.isEmpty {
            out.append(PanelConfig(file: "\(folder)/\(unused.removeFirst())"))
        }
        return (out, unused)
    }
}

// MARK: - Inventory and merge (§ v4 › Media on several Macs; T14)

/// One file as a Mac's scan found it.
public struct InventoryFile: Codable, Equatable {
    public var name: String          // file name inside its work folder
    public var size: Int64
    public var modified: Double      // seconds since 1970; with size, the "still there, unchanged" check
    public var duration: Double
    public var fps: Double
    public var hasAudio: Bool

    public init(name: String, size: Int64 = 0, modified: Double = 0, duration: Double, fps: Double = 30, hasAudio: Bool = false) {
        self.name = name; self.size = size; self.modified = modified
        self.duration = duration; self.fps = fps; self.hasAudio = hasAudio
    }
}

/// What one Mac has: its displays, and each work folder's video files.
public struct Inventory: Codable, Equatable {
    public var machine: String
    public var displays: Int
    public var folders: [String: [InventoryFile]]   // folder name → its video files

    public init(machine: String, displays: Int, folders: [String: [InventoryFile]]) {
        self.machine = machine; self.displays = displays; self.folders = folders
    }
}

public enum PlaylistMerge {
    /// Folds every Mac's inventory into the playlist (§ v4 › Getting works in).
    ///
    /// The folder NAME is the join key across Macs: "Smith" on the conductor
    /// and "Smith" on a player are one work. Rules:
    /// - existing works keep their order and settings (a rescan doesn't
    ///   disturb what a person has set up);
    /// - a folder no work has yet becomes a new work, appended in name order;
    /// - a Mac with no screens set for a work gets them from its scan, so a
    ///   player that joins after the conductor scanned still fills in;
    /// - a Mac that already has screens for a work keeps them (they may have
    ///   been set by hand).
    public static func merge(_ works: [Work], with inventories: [Inventory]) -> [Work] {
        var result = works
        let known = Set(works.map(\.name))
        let newNames = Set(inventories.flatMap { $0.folders.keys }).subtracting(known)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        result += newNames.map { Work(name: $0) }
        for i in result.indices {
            for inv in inventories where result[i].screens[inv.machine] == nil {
                guard let files = inv.folders[result[i].name] else { continue }
                result[i].screens[inv.machine] = FolderScan.assign(folder: result[i].name, files: files.map(\.name),
                                                                   displays: inv.displays).panels
            }
        }
        return result
    }

    /// A work's length: its longest file on any Mac (§ v4 › Playing). Files
    /// the inventories don't know about count as 0.
    public static func length(of work: Work, in inventories: [Inventory]) -> Double {
        var longest = 0.0
        for inv in inventories {
            // Panel files are "folder/name", relative to that Mac's media folder.
            for path in work.screens[inv.machine]?.compactMap(\.file) ?? [] {
                let folder = (path as NSString).deletingLastPathComponent
                let name = (path as NSString).lastPathComponent
                if let f = inv.folders[folder]?.first(where: { $0.name == name }) { longest = max(longest, f.duration) }
            }
        }
        return longest
    }
}

// MARK: - Timeline (§ v4 › Timing; T15)

/// Where the playlist is at a given show time.
public enum PlaylistPosition: Equatable {
    case work(index: Int, elapsed: Double)   // seconds into that work (all its repeats)
    case gap(next: Int)                      // black between works; `next` is loading
    case waiting                             // before the anchored start
    case ended                               // past the last work, playlist not looping
}

/// [claude] The playlist's timeline as a pure function of show time.
///
/// Every Mac holds the same entries (lengths measured on each Mac, merged by
/// the conductor) and the same ANCHOR: "work k started at show time t0".
/// From those alone, any Mac can say what should be on screen at any instant,
/// so an automatic change of work needs no message: they all change at the
/// same show time. Only a person's action (Next, jump) moves the anchor.
/// This is the same idea as v1's shared start h0, extended from one clip to a
/// sequence: DERIVE the state from a shared reference, don't SEND it.
public struct Timeline {
    public struct Entry: Equatable {
        public var length: Double            // one play of the work
        public var `repeat`: Repeat
        public init(length: Double, repeat: Repeat) { self.length = length; self.repeat = `repeat` }

        /// How long the work occupies: length × repeats; nil = until moved on.
        var span: Double? {
            switch `repeat` {
            case .times(let n): return length * Double(n)
            case .untilNext: return nil
            }
        }
    }

    public var entries: [Entry]
    public var settings: PlaylistSettings

    public init(entries: [Entry], settings: PlaylistSettings) {
        self.entries = entries; self.settings = settings
    }

    /// The next playable work after `i`, skipping empty ones (length 0: no
    /// files anywhere), or nil at the end of a non-looping playlist.
    public func next(after i: Int) -> Int? {
        for step in 1...max(entries.count, 1) {
            let j = i + step
            if j >= entries.count && !settings.loop { return nil }
            let k = j % entries.count
            if entries[k].length > 0 { return k }
        }
        return nil
    }

    /// [claude] The playable work before `i` (for ← on the conductor), or nil
    /// at the start of a non-looping playlist.
    public func previous(before i: Int) -> Int? {
        for step in 1...max(entries.count, 1) {
            let j = i - step
            if j < 0 && !settings.loop { return nil }
            let k = ((j % entries.count) + entries.count) % entries.count
            if entries[k].length > 0 { return k }
        }
        return nil
    }

    /// [claude] `k` if it is playable, else the next one that is: the work
    /// that actually plays when the timeline is anchored at `k`.
    public func playable(from k: Int) -> Int? {
        guard entries.indices.contains(k) else { return nil }
        return entries[k].length > 0 ? k : next(after: k)
    }

    /// What should be playing at show time `t`, given that work `k` started
    /// at show time `t0`.
    public func position(at t: Double, anchor k: Int, start t0: Double) -> PlaylistPosition {
        segment(at: t, anchor: k, start: t0).position
    }

    /// [claude] One stretch of the timeline: a play of a work (all its
    /// repeats), a gap, the wait before the anchor, or the end.
    public struct Segment: Equatable {
        public var position: PlaylistPosition   // at the time asked about
        public var begins: Double               // show time it began (-∞ while waiting)
        public var ends: Double?                // show time it ends; nil = not by itself
    }

    /// [claude] Where the playlist is at show time `t`, and the edges of the
    /// stretch it is in.
    ///
    /// The edges are what playback needs: knowing that the current work ends
    /// at show time 1234.5, it sets ONE timer for that moment, rather than
    /// asking "has it changed yet?" many times a second. That is the
    /// difference between SCHEDULING an event and POLLING for it; polling
    /// would also be late by up to its own interval at every change.
    public func segment(at t: Double, anchor k: Int, start t0: Double) -> Segment {
        guard entries.indices.contains(k) else { return Segment(position: .ended, begins: t0, ends: nil) }
        if t < t0 { return Segment(position: .waiting, begins: -.infinity, ends: t0) }
        var i = k
        if entries[i].length <= 0 {
            guard let n = next(after: i) else { return Segment(position: .ended, begins: t0, ends: nil) }
            i = n
        }
        // One full cycle of a looping playlist, if every work has an end: lets
        // a time days after the anchor be answered in one step, not by
        // walking through thousands of works. MODULAR ARITHMETIC, as the loop
        // position of a single clip is (SyncMath.expected).
        let cycle: Double? = settings.loop && entries.allSatisfy({ $0.span != nil })
            ? entries.filter { $0.length > 0 }.reduce(0) { $0 + $1.span! + settings.gap } : nil
        var walkedCycle = false
        let first = i
        var begins = t0                       // when stretch i began
        while true {
            guard let span = entries[i].span else {   // until moved on
                return Segment(position: .work(index: i, elapsed: t - begins), begins: begins, ends: nil)
            }
            if t - begins < span { return Segment(position: .work(index: i, elapsed: t - begins), begins: begins, ends: begins + span) }
            begins += span
            guard let n = next(after: i) else { return Segment(position: .ended, begins: begins, ends: nil) }
            if t - begins < settings.gap { return Segment(position: .gap(next: n), begins: begins, ends: begins + settings.gap) }
            begins += settings.gap
            i = n
            if i == first, !walkedCycle, let cycle, cycle > 0 {
                begins += ((t - begins) / cycle).rounded(.down) * cycle    // skip whole cycles
                walkedCycle = true
            }
        }
    }

    /// Where one screen's file should be, `elapsed` seconds into a work of
    /// `workLength` (one play), or nil if that screen should be black.
    /// "black": each play of the work restarts the file, which shows once
    /// and then goes black; "loop": the file repeats on its own length.
    public static func screenPosition(elapsed: Double, workLength: Double, fileDuration: Double, shorter: Shorter) -> Double? {
        guard fileDuration > 0, workLength > 0 else { return nil }
        switch shorter {
        case .loop:
            return elapsed.truncatingRemainder(dividingBy: fileDuration)
        case .black:
            let intoPlay = elapsed.truncatingRemainder(dividingBy: workLength)
            return intoPlay < fileDuration ? intoPlay : nil
        }
    }
}

// MARK: - One screen's player item (§ v4 › Playing)

/// [claude] How one screen's player item is laid out for one work, so that
/// the item's own time is always "seconds into the work".
///
/// With that property, everything playback already does (start every screen
/// at a shared instant, join a show late, check drift once a second) works
/// per work unchanged: each asks the item to be at "seconds into the work".
/// The layout is the `Timeline.screenPosition` rule made into media:
/// - `loop`: the clip end to end, as v1 loops a panel;
/// - `black`: per play of the work, the clip then EMPTY TIME up to the work's
///   length (an empty edit decodes nothing, so the screen shows black).
///
/// No piece is ever empty at the end. `proofs/empty-range-probe.swift` found
/// that AVFoundation drops a trailing empty range (a 6 s layout became a 4 s
/// item), so the item would stop early and hold its last frame. The item
/// ends on a clip instead, and the app hides a screen whose item has ended
/// before its work has.
public enum ItemLayout {
    public enum Piece: Equatable {
        case clip                      // the whole file
        case empty(Double)             // seconds of nothing
    }

    /// The pieces for a file of `fileDuration` in a work of `workLength` (one
    /// play). A work that is "until next" has no end, so its item covers
    /// `cover` seconds (v1's 24 h), as a v1 panel does; at most `maxPieces`.
    public static func pieces(fileDuration d: Double, workLength l: Double, repeat r: Repeat,
                              shorter: Shorter, cover: Double, maxPieces: Int) -> [Piece] {
        guard d > 0 else { return [] }
        let span: Double
        switch r {
        case .times(let n): span = max(l, d) * Double(n)
        case .untilNext: span = cover
        }
        let tail = l - d
        // A file as long as the work (within a millisecond) is just played
        // back to back, whatever `shorter` says: there is no black to show.
        if shorter == .loop || tail < 0.001 {
            return Array(repeating: .clip, count: SyncMath.repeats(duration: d, cover: span, maxSegments: maxPieces))
        }
        let plays = SyncMath.repeats(duration: l, cover: span, maxSegments: max(1, (maxPieces + 1) / 2))
        var out: [Piece] = []
        for k in 0..<plays {
            if k > 0 { out.append(.empty(tail)) }
            out.append(.clip)
        }
        return out
    }

    /// How long an item laid out as `pieces` lasts.
    public static func duration(_ pieces: [Piece], fileDuration d: Double) -> Double {
        pieces.reduce(0) { total, p in
            switch p {
            case .clip: return total + d
            case .empty(let s): return total + s
            }
        }
    }
}
