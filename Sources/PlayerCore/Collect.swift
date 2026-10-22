import Foundation

// [claude] Collecting a show's files for archiving, and importing a folder
// (docs/architecture.md § v4 › Collecting and importing).
//
// Like the rest of PlayerCore these are PURE FUNCTIONS: they decide what to
// copy where, and what the show should then say, from names and paths alone.
// The app does the copying. Splitting the DECISION from the I/O is what lets
// every naming rule below be tested without touching a disk.

public enum Collect {
    /// One file to copy: `source` is a full path; `dest` is relative to the
    /// archive's root ("Smith/1.mp4").
    public struct Copy: Equatable {
        public var source: String
        public var dest: String
        public init(source: String, dest: String) { self.source = source; self.dest = dest }
    }

    public struct Plan: Equatable {
        public var copies: [Copy]
        /// The works as they should read inside the archive: this Mac's
        /// panels point at the copies, relative to the archive's root.
        public var works: [Work]
    }

    /// What to copy to archive `works` on one Mac, and the works rewritten to
    /// point at the copies.
    ///
    /// The archive has the LAYOUT OF A MEDIA FOLDER: one subfolder per work,
    /// named after it, holding its files. So an archive needs no format of
    /// its own: point a Mac's media folder at it and the rewritten show plays,
    /// or Import / Scan it and its folders become works again.
    ///
    /// Only `machine`'s panels change. Each Mac collects its own files (Mat):
    /// the other Macs' paths are on their disks, and stay as they were.
    /// `resolve` turns a panel's path (relative to the media folder, or full)
    /// into a full path, the way the app does. `takenFolders` (lowercased)
    /// are names already in the destination, which a work folder must avoid.
    ///
    /// [claude] SCREEN NUMBERS ROUND-TRIP (Mat, 2026-10-22): if importing the
    /// copies by the folder-scan rule wouldn't put them back on the same
    /// screens (a hand-set order, a black screen between two files), every
    /// file of that work is named for its screen, "_N" across the tableau
    /// (`firstScreen` = this Mac's display 1): a name already ending in its
    /// own "_N" is kept, others get "_N" added ("intro.mov" on screen 2 →
    /// "intro_2.mov"). When the scan would already restore them, names are
    /// left exactly as they were.
    public static func plan(works: [Work], machine: String, resolve: (String) -> String,
                            takenFolders: Set<String> = [], firstScreen: Int = 1) -> Plan {
        var copies: [Copy] = []
        var out = works
        var folders = takenFolders
        for (w, work) in works.enumerated() {
            guard let panels = work.screens[machine] else { continue }
            let folder = uniqueName(folderName(work.name), taken: folders)
            folders.insert(folder.lowercased())
            // A file shown on two screens of one work is copied once: the
            // map remembers which name each source was given.
            var given: [String: String] = [:]
            var names: Set<String> = []
            var order: [String] = []                              // sources, first use first
            for p in panels {
                guard let file = p.file else { continue }
                let source = resolve(file)
                guard given[source] == nil else { continue }
                let name = uniqueName((source as NSString).lastPathComponent, taken: names)
                names.insert(name.lowercased())
                given[source] = name
                order.append(source)
            }
            // Would a scan of these names rebuild the same screens?
            let intended = panels.map { $0.file.map { given[resolve($0)]! } }
            let scanned = FolderScan.assign(folder: "", files: Array(given.values), displays: panels.count,
                                            firstScreen: firstScreen).panels.map { $0.file.map { String($0.dropFirst()) } }
            if scanned != intended {
                var numbered: Set<String> = []
                for (i, p) in panels.enumerated() {
                    guard let file = p.file else { continue }
                    let source = resolve(file), n = firstScreen + i
                    let name = given[source]!
                    guard !numbered.contains(source) else { continue }     // its first screen names it
                    numbered.insert(source)
                    if FolderScan.screenNumber(name) != n {
                        let ext = (name as NSString).pathExtension
                        let base = (name as NSString).deletingPathExtension
                        given[source] = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
                    }
                }
            }
            for source in order { copies.append(Copy(source: source, dest: "\(folder)/\(given[source]!)")) }
            var rewritten = panels
            for (i, p) in panels.enumerated() {
                guard let file = p.file else { continue }       // black stays black
                rewritten[i].file = "\(folder)/\(given[resolve(file)]!)"
            }
            out[w].screens[machine] = rewritten
        }
        return Plan(copies: copies, works: out)
    }

    /// [claude] Collect INTO this library (Mat, 2026-10-22: "check its
    /// existing structure first so it's not duplicating files, build from
    /// what it has already"). Only files OUTSIDE the works folder (linked by
    /// Import or Choose) are copied, each into its work's folder in Works/:
    /// the folder the work's library files are already in, or else a new one
    /// named after the work (never another work's folder). Files already in
    /// the library are left exactly where they are. `dest` is relative to the
    /// works folder; the returned works point at the copies.
    ///
    /// `folders` lists the works folder's subfolders (as they are now) and
    /// `listing` a subfolder's files, so names already there are avoided.
    public static func gather(works: [Work], machine: String, worksFolder: String,
                              folders: Set<String>, listing: (String) -> [String]) -> Plan {
        let root = worksFolder.hasSuffix("/") ? worksFolder : worksFolder + "/"
        func inside(_ f: String) -> Bool { !f.hasPrefix("/") || f.hasPrefix(root) }
        var copies: [Copy] = []
        var out = works
        var takenFolders = Set(folders.map { $0.lowercased() })
        for (w, work) in works.enumerated() {
            guard let panels = work.screens[machine], panels.contains(where: { $0.file.map { !inside($0) } ?? false }) else { continue }
            // Beside the work's library files if it has any; else its own new folder.
            let relativeParents = Set(panels.compactMap(\.file).filter { !$0.hasPrefix("/") }
                .map { ($0 as NSString).deletingLastPathComponent }).filter { !$0.isEmpty }
            let folder: String
            if relativeParents.count == 1, let only = relativeParents.first {
                folder = only
            } else {
                folder = uniqueName(folderName(work.name), taken: takenFolders)
                takenFolders.insert(folder.lowercased())
            }
            var names = Set(listing(folder).map { $0.lowercased() })
            var given: [String: String] = [:]
            var rewritten = panels
            for (i, p) in panels.enumerated() {
                guard let f = p.file, !inside(f) else { continue }
                if given[f] == nil {
                    let name = uniqueName((f as NSString).lastPathComponent, taken: names)
                    names.insert(name.lowercased())
                    given[f] = name
                    copies.append(Copy(source: f, dest: "\(folder)/\(name)"))
                }
                rewritten[i].file = "\(folder)/\(given[f]!)"
            }
            out[w].screens[machine] = rewritten
        }
        return Plan(copies: copies, works: out)
    }

    /// `name`, or "name 2.ext", "name 3.ext", … if it's taken. `taken` holds
    /// LOWERCASED names, because a Mac's disk is normally case-insensitive:
    /// "Clip.mp4" and "clip.mp4" are the same file there, and copying the
    /// second would silently replace the first.
    public static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name.lowercased()) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// A work's name made safe as a folder name. "/" would make a subfolder
    /// and ":" shows as "/" in Finder, so both become "-"; a leading "." would
    /// hide the folder, and a scan skips hidden folders, so it is dropped.
    public static func folderName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Untitled" : s
    }
}

/// [claude] Compose ahead, step 4 (Mat, 2026-10-22): one folder per Mac,
/// ready to copy to it. Each kit holds the files that Mac's screens play, at
/// the SAME paths they have in this library (Works/<work>/<file>), so the
/// show's paths stay true on the composer and in every kit. The conductor's
/// kit (a gallery Mac conducting) also carries the show.
public enum Kits {
    public struct Kit: Equatable {
        public var machine: String
        public var label: String
        public var copies: [Collect.Copy]     // dest relative to the kit's Works/
        public var withShow: Bool
        /// Files on its screens linked from outside the library: not copied
        /// (Collect the show first).
        public var linked: [String]
    }

    /// A kit for every Mac with screens, plus the conductor's if it has none
    /// (it still needs the show). `conductor` nil: this Mac conducts and
    /// keeps the show itself.
    public static func plan(show: Show, conductor: String?, resolve: (String) -> String) -> [Kit] {
        var kits: [Kit] = []
        for m in show.machines where m.screenCount > 0 || m.name == conductor {
            var seen: Set<String> = [], copies: [Collect.Copy] = [], linked: [String] = []
            for work in show.works {
                for f in (work.screens[m.name] ?? []).prefix(m.screenCount).compactMap(\.file) where seen.insert(f).inserted {
                    if f.hasPrefix("/") { linked.append(f) } else { copies.append(Collect.Copy(source: resolve(f), dest: f)) }
                }
            }
            kits.append(Kit(machine: m.name, label: m.displayName, copies: copies, withShow: m.name == conductor, linked: linked))
        }
        return kits
    }
}

/// Importing a folder from anywhere (Mat: LINK IN PLACE). Nothing is copied:
/// panels hold full paths to the files where they are, which is fast and costs
/// no disk, at the price that the show breaks if that folder moves. Collect is
/// the way to gather such files later.
public enum FolderImport {
    public struct Result: Equatable {
        public var works: [Work]                 // new works, in order
        public var skipped: [String]             // names the playlist already has
        public var leftOver: [String: [String]]  // work name → files beyond the displays
    }

    /// The works in folder `root` for one Mac. The folder's own videos are one
    /// work named after it; each subfolder with videos is another, in name
    /// order. So a single student's folder and a whole class folder (or a
    /// collected archive) both import. Screens are assigned by the scan rule
    /// (FolderScan). A name the playlist already has is skipped, as a rescan
    /// never disturbs a work already set up.
    ///
    /// `rootFiles` is the root's listing; `subfolders` maps each subfolder's
    /// name to its listing.
    public static func works(root: String, rootFiles: [String], subfolders: [String: [String]],
                             machine: String, displays: Int, existing: Set<String>, firstScreen: Int = 1) -> Result {
        var result = Result(works: [], skipped: [], leftOver: [:])
        var taken = existing
        let sorted = subfolders.keys.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let candidates = [((root as NSString).lastPathComponent, root, rootFiles)]
            + sorted.map { ($0, (root as NSString).appendingPathComponent($0), subfolders[$0] ?? []) }
        for (name, path, files) in candidates where !FolderScan.videos(files).isEmpty {
            guard !taken.contains(name) else { result.skipped.append(name); continue }
            taken.insert(name)
            // `folder` is the full path, so the panels hold full paths.
            let (panels, left) = FolderScan.assign(folder: path, files: files, displays: displays, firstScreen: firstScreen)
            result.works.append(Work(name: name, screens: [machine: panels]))
            if !left.isEmpty { result.leftOver[name] = left }
        }
        return result
    }
}
