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
    public static func plan(works: [Work], machine: String, resolve: (String) -> String,
                            takenFolders: Set<String> = []) -> Plan {
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
            var rewritten = panels
            for (i, p) in panels.enumerated() {
                guard let file = p.file else { continue }       // black stays black
                let source = resolve(file)
                let name: String
                if let known = given[source] {
                    name = known
                } else {
                    name = uniqueName((source as NSString).lastPathComponent, taken: names)
                    names.insert(name.lowercased())
                    given[source] = name
                    copies.append(Copy(source: source, dest: "\(folder)/\(name)"))
                }
                rewritten[i].file = "\(folder)/\(name)"
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
                             machine: String, displays: Int, existing: Set<String>) -> Result {
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
            let (panels, left) = FolderScan.assign(folder: path, files: files, displays: displays)
            result.works.append(Work(name: name, screens: [machine: panels]))
            if !left.isEmpty { result.leftOver[name] = left }
        }
        return result
    }
}
