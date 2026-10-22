import Foundation

// [claude] v4 P4b, zero setup (docs/architecture.md § v4 › Zero setup): send
// a Mac the app and a `tableauX` folder, open the app, and it finds its files,
// works out its role and opens its show without anyone setting anything.
// These are the rules, as PURE FUNCTIONS of folder listings; the app reads
// the disk and asks them.

public enum ShowFolder {
    /// The folder name looked for (Mat, 2026-10-22). A Mac's disk ignores
    /// case, so "Tableaux" is found too.
    public static let name = "tableauX"
    public static let showExtension = "tableaux"

    /// Does this listing look like a tableauX folder: a show file in it, or a
    /// subfolder that holds videos? `subfolders` maps each subfolder's name
    /// to its listing. The app's own folder only counts if it does, so an
    /// app sitting in /Applications or Downloads doesn't take that folder
    /// over as its media.
    ///
    /// [claude] Only a clear MARKER counts: a show file, or a `Works` or
    /// `Shows` folder. "Any folder with videos" used to count too, and an
    /// app opened from Downloads (Mat's M5, 2026-10-22) took Downloads as
    /// its library: every folder with a video in it became a work, one of
    /// 16 screens. A folder FOUND BY NAME (`tableauX`) needs no marker.
    public static func isShowFolder(files: [String], subfolders: [String: [String]]) -> Bool {
        files.contains { ($0 as NSString).pathExtension.lowercased() == showExtension }
            || subfolders.keys.contains { $0.caseInsensitiveCompare(worksName) == .orderedSame
                                          || $0.caseInsensitiveCompare(showsName) == .orderedSame }
    }

    /// [claude] Where a library is created when the search finds none (Mat,
    /// 2026-10-22): ~/Movies/tableauX. The same place on every Mac, and one
    /// macOS doesn't ask permission for.
    public static func defaultLibrary(home: String) -> String {
        ((home as NSString).appendingPathComponent("Movies") as NSString).appendingPathComponent(name)
    }

    public enum Role: Equatable { case conductor, player, standalone }

    /// The role a library gives a Mac, unless one was chosen by hand (Mat:
    /// the folder decides). Show files = Conductor; works but no shows =
    /// Player; an empty library (a fresh Mac) = Standalone.
    public static func role(shows: Int, works: Int) -> Role {
        shows > 0 ? .conductor : works > 0 ? .player : .standalone
    }

    // MARK: The library (P4d, § v4 › Library: works and shows) [claude]

    public static let worksName = "Works"
    public static let showsName = "Shows"

    /// Where a library keeps its works and its show files. With a `Works`
    /// folder: works in `Works/`, shows in `Shows/`. Without one (the layout
    /// before libraries: works directly inside, show files beside them):
    /// both are the root, so every existing folder keeps working.
    public static func layout(root: String, subfolders: [String]) -> (works: String, shows: String) {
        guard let w = subfolders.first(where: { $0.caseInsensitiveCompare(worksName) == .orderedSame }) else {
            return (root, root)
        }
        let s = subfolders.first(where: { $0.caseInsensitiveCompare(showsName) == .orderedSame }) ?? showsName
        return ((root as NSString).appendingPathComponent(w), (root as NSString).appendingPathComponent(s))
    }

    /// Every work in the pool: this Mac's work folders and every work a
    /// player reported, once each, in name order. "Add from library"
    /// offers the ones the current show doesn't have.
    /// [claude] A folder reported under a FULL PATH ("/Users/…") holds files a
    /// player linked to one of its screens from outside its library: they
    /// are reported so lengths and the file check include them, but they
    /// are not works.
    public static func pool(own: [String], inventories: [Inventory]) -> [String] {
        Set(own + inventories.flatMap { $0.folders.keys }).filter { !$0.hasPrefix(".") && !$0.hasPrefix("/") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Where to look, in order, after a folder chosen by hand: the app's own
    /// folder, a `tableauX` folder beside the app (Mat's layout, 2026-10-22:
    /// the app and a tableauX folder side by side), then `tableauX` in the
    /// home folder, Movies and the Desktop. Home and Movies before the
    /// Desktop because macOS asks permission before an app reads the
    /// Desktop; a folder found without asking is a step saved.
    public static func candidates(appFolder: String?, home: String) -> [(path: String, mustLookLikeAShow: Bool)] {
        var out: [(String, Bool)] = []
        if let appFolder {
            out.append((appFolder, true))
            out.append(((appFolder as NSString).appendingPathComponent(name), false))
        }
        for parent in ["", "Movies", "Desktop"] {
            let p = parent.isEmpty ? home : (home as NSString).appendingPathComponent(parent)
            out.append(((p as NSString).appendingPathComponent(name), false))
        }
        return out
    }

    /// The media folder: the one chosen by hand if it still exists, else the
    /// first candidate that exists (and, for the app's folder, looks like a
    /// show). `listing` returns a folder's files and subfolder listings, or
    /// nil if it doesn't exist.
    public static func pick(chosen: String?, appFolder: String?, home: String,
                            listing: (String) -> (files: [String], subfolders: [String: [String]])?) -> String? {
        if let chosen, !chosen.isEmpty, listing(chosen) != nil { return chosen }
        for c in candidates(appFolder: appFolder, home: home) {
            guard let l = listing(c.path) else { continue }
            if !c.mustLookLikeAShow || isShowFolder(files: l.files, subfolders: l.subfolders) { return c.path }
        }
        return nil
    }

    /// The show files in a folder's listing.
    public static func shows(in files: [String]) -> [String] {
        files.filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == showExtension }
    }

    /// Which show to open at launch (§ Zero setup): the last one if it is in
    /// the media folder; else the newest in the folder (a folder sent with an
    /// updated show replaces the old one). Failing both, the last show from
    /// elsewhere ONLY if the folder was chosen by hand (or there is none):
    /// a show's files are relative to the folder it was made with, so
    /// opening it against a folder that was merely found pairs it with the
    /// wrong files (Mat's run, 2026-10-22: every file "missing"). nil = start
    /// a fresh show from the folder. `folderShows`: full paths and dates.
    public static func showToOpen(last: String?, folder: String?, folderChosen: Bool,
                                  folderShows: [(path: String, modified: Double)]) -> String? {
        if let last, let folder, (last as NSString).deletingLastPathComponent == folder,
           folderShows.contains(where: { $0.path == last }) { return last }
        if let newest = folderShows.max(by: { $0.modified < $1.modified }) { return newest.path }
        return folder == nil || folderChosen ? last : nil
    }
}
