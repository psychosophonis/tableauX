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
    public static func isShowFolder(files: [String], subfolders: [String: [String]]) -> Bool {
        files.contains { ($0 as NSString).pathExtension.lowercased() == showExtension }
            || subfolders.contains { !$0.key.hasPrefix(".") && !FolderScan.videos($0.value).isEmpty }
    }

    /// Where to look, in order, after a folder chosen by hand: the app's own
    /// folder, then `tableauX` in the home folder, Movies and the Desktop.
    /// Home and Movies first because macOS asks permission before an app
    /// reads the Desktop; a folder found without asking is a step saved.
    public static func candidates(appFolder: String?, home: String) -> [(path: String, mustLookLikeAShow: Bool)] {
        var out: [(String, Bool)] = []
        if let appFolder { out.append((appFolder, true)) }
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
