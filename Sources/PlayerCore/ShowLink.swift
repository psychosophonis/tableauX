import Foundation

// [claude] v4 P3b: the conductor and its players agree on ONE playlist
// (docs/architecture.md § v4 › Media on several Macs, Timing).
//
// The clock and the show state stay on UDP, where a late packet is worse
// than a lost one. What travels here is bigger and must not be lost: each
// player's inventory of files, and the conductor's playlist with the lengths
// every Mac must time it by. So it goes over TCP, one connection per player.
// This file is the part with no network in it: the messages, how they are
// cut out of a byte stream, and how the conductor folds an inventory in.

/// Everything said over the link.
///
/// Sendable: it crosses from the link's network queue to the main actor.
/// It is made only of value types (strings, numbers, arrays, structs of
/// them), so a copy shares nothing; "@unchecked" only because the show's
/// model types predate Sendable and don't declare it.
public enum LinkMessage: Codable, Equatable, @unchecked Sendable {
    /// Player → conductor, first thing on connecting: who it is, and which
    /// build it runs (Macs on different builds may not agree on a show).
    case hello(machine: String, build: String)
    /// Player → conductor: what its media folder holds (§ Inventory).
    case inventory(Inventory)
    /// Player → conductor: what stops it playing its part, if anything
    /// (missing or unreadable files). Empty = ready.
    case report(machine: String, blocking: [String])
    /// Conductor → player: the playlist, and each work's length, which every
    /// Mac must use so they all compute the same timeline (§ Timing).
    case show(Show, lengths: [Double])
    /// [claude] Player → conductor: a person on the player set one of its
    /// own screens (Mat, 2026-10-22: assign files on the client, "these
    /// changes should report back to the conductor"). The conductor records
    /// it in the show and shares the show back.
    case setScreen(machine: String, work: String, index: Int, panel: PanelConfig)
}

/// Cutting messages out of a TCP byte stream.
///
/// TCP delivers BYTES, not messages: one read may hold half a message, or
/// two and a bit. So each message goes out as a LENGTH PREFIX (4 bytes,
/// big-endian) followed by that many bytes of JSON, and the reader keeps a
/// buffer, taking whole messages off the front as they complete. This is
/// the standard way to put messages on a stream.
public enum LinkFraming {
    /// Far above any real playlist (a 100-work show is ~100 KB), low enough
    /// that a corrupt or foreign length can't make a Mac allocate gigabytes.
    public static let maxMessage = 16 << 20

    public enum Failure: Error, Equatable { case tooLong(Int) }

    public static func frame(_ m: LinkMessage) throws -> Data {
        let body = try JSONEncoder().encode(m)
        let n = UInt32(body.count)
        return Data([UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + body
    }

    public struct Reader {
        private var buffer = Data()
        /// Frames that arrived whole but didn't decode: a message from a
        /// newer build, say. Skipped, not fatal: the frame boundary is still
        /// known, so the stream stays in step.
        public private(set) var skipped = 0

        public init() {}

        /// Adds `bytes`, returns every message now complete. Throws if a
        /// length is over the limit: the stream can't be trusted after that,
        /// and the caller closes the connection.
        public mutating func feed(_ bytes: Data) throws -> [LinkMessage] {
            buffer.append(bytes)
            var out: [LinkMessage] = []
            while buffer.count >= 4 {
                let b = [UInt8](buffer.prefix(4))
                let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                guard n <= LinkFraming.maxMessage else { throw Failure.tooLong(n) }
                guard buffer.count >= 4 + n else { break }       // the rest hasn't arrived yet
                let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + n)
                buffer.removeFirst(4 + n)
                if let m = try? JSONDecoder().decode(LinkMessage.self, from: body) { out.append(m) } else { skipped += 1 }
            }
            return out
        }
    }
}

/// The conductor's side of the agreement: folding players into its show.
public enum SharedShow {
    /// The show with one player's inventory folded in.
    ///
    /// - The player's machine is added the first time it is heard from, at
    ///   the end: the machine order numbers the screens across Macs, so it
    ///   must not shuffle when players connect in a different order next
    ///   time. Saved in the conductor's show, it stays put.
    /// - Its display count is updated.
    /// - Works: PlaylistMerge (new folders become works; screens already
    ///   set are kept), then new displays take left-over files
    ///   (FolderScan.fill), as on the conductor's own Mac.
    ///
    /// `conductor` is the conductor's own name. A ONE-MACHINE show saved
    /// under another name plays on any Mac (Show.machineIndex's fallback),
    /// but only while it has one machine: the first player to join would
    /// end that, and the conductor would lose its own part. So the
    /// conductor first ADOPTS the lone entry, unless it belongs to the
    /// player now joining (then the show was that player's).
    /// `addingNewWorks`: see PlaylistMerge.merge (false for a saved show).
    public static func merge(_ show: Show, with inventory: Inventory, conductor: String,
                             addingNewWorks: Bool = true) -> Show {
        var s = show
        if s.machines.count == 1, let lone = s.machines.first?.name,
           lone != conductor, lone != inventory.machine {
            s.machines[0].name = conductor
            for w in s.works.indices {
                if let panels = s.works[w].screens.removeValue(forKey: lone) { s.works[w].screens[conductor] = panels }
            }
        }
        // [claude] A Mac's display count is the show's DESIGN (Mat,
        // 2026-10-22: "preview as if they were connected"): set from the
        // report when the Mac is first added, grown if it reports more,
        // never shrunk by a report of fewer (a display unplugged, a laptop
        // standing in). Only a person makes it smaller.
        let designed: Int
        if let i = s.machines.firstIndex(where: { $0.name == inventory.machine }) {
            s.machines[i].displays = max(s.machines[i].displays, inventory.displays)
            designed = s.machines[i].displays
        } else {
            // A Mac joining the show is sized by what its works need, not
            // only by what it has plugged in (Mat, 2026-10-22).
            let first = 1 + s.machines.reduce(0) { $0 + $1.screenCount }
            let needed = FolderScan.displaysNeeded(inventory.folders.mapValues { $0.map(\.name) }, firstScreen: first)
            designed = min(max(inventory.displays, needed), 16)
            s.machines.append(Machine(name: inventory.machine, displays: designed))
        }
        var asDesigned = inventory
        asDesigned.displays = designed
        // The machine is in the show now, so its place in the tableau is known.
        let first = firstScreen(s, of: inventory.machine)
        s.works = PlaylistMerge.merge(s.works, with: [asDesigned], firstScreens: [inventory.machine: first],
                                      addingNewWorks: addingNewWorks)
        for w in s.works.indices {
            let set = s.works[w].screens[inventory.machine] ?? []
            guard let folder = FolderScan.folder(of: set, work: s.works[w].name),
                  let files = inventory.folders[folder] else { continue }
            let (panels, _) = FolderScan.fill(set, folder: folder, files: files.map(\.name), displays: designed,
                                              firstScreen: first)
            if panels != set { s.works[w].screens[inventory.machine] = panels }
        }
        return s
    }

    /// [claude] Which part a Mac is, judged by its FILES (Mat, 2026-10-22:
    /// institutional Macs can't be renamed; "the file structure should
    /// support the build"). Each candidate part scores the number of
    /// distinct files its screens use (relative paths, every work, within
    /// its displays) that this Mac has. The best wins only if it shares at
    /// least one file and nothing ties with it: a wrong guess would put one
    /// Mac's screens on another, so when in doubt a person decides.
    public static func claim(_ show: Show, files: Set<String>, candidates: [String]) -> String? {
        let scored = candidates.compactMap { name -> (String, Int)? in
            guard let m = show.machines.first(where: { $0.name == name }) else { return nil }
            let used = Set(show.works.flatMap { ($0.screens[name] ?? []).prefix(m.screenCount).compactMap(\.file) })
            return (name, used.intersection(files).count)
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 > 0, scored.dropFirst().first?.1 != best.1 else { return nil }
        return best.0
    }

    /// The relative paths ("Work/file") an inventory holds, for `claim`.
    public static func files(of inventory: Inventory) -> Set<String> {
        Set(inventory.folders.filter { !$0.key.hasPrefix("/") }.flatMap { folder, files in files.map { "\(folder)/\($0.name)" } })
    }

    /// [claude] The show with one screen of one Mac set (a player's own edit,
    /// LinkMessage.setScreen). The Mac's screens for that work are padded
    /// with black up to `index`; nothing else changes. An unknown work or a
    /// Mac not in the show: unchanged.
    public static func setScreen(_ show: Show, machine: String, work: String, index: Int, panel: PanelConfig) -> Show {
        guard index >= 0, index < 16, show.machines.contains(where: { $0.name == machine }),
              let w = show.works.firstIndex(where: { $0.name == work }) else { return show }
        var s = show
        var panels = s.works[w].screens[machine] ?? []
        while panels.count <= index { panels.append(PanelConfig()) }
        panels[index] = panel
        s.works[w].screens[machine] = panels
        return s
    }

    /// [claude] The tableau screen number of machine `m`'s display 1: one
    /// more than all the displays of the Macs before it in the show (§ v4 ›
    /// Model, screens numbered across the Macs). A Mac not in the show: 1.
    public static func firstScreen(_ show: Show, of m: String) -> Int {
        guard let i = show.machines.firstIndex(where: { $0.name == m }) else { return 1 }
        return 1 + show.machines[..<i].reduce(0) { $0 + $1.screenCount }   // a conduct-only Mac adds none
    }

    /// Each work's length: its longest file on any Mac (§ v4 › Playing).
    /// `own` is the conductor's own longest file per work (measured from
    /// its files, which have no inventory); the players' come from theirs.
    public static func lengths(_ show: Show, own: [Double], inventories: [Inventory]) -> [Double] {
        show.works.indices.map { w in
            max(w < own.count ? own[w] : 0, PlaylistMerge.length(of: show.works[w], in: inventories))
        }
    }
}
