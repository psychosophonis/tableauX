import AppKit
import AVFoundation
import PlayerCore
import SwiftUI              // [claude] for Binding (panelBinding)
import SystemConfiguration
import UniformTypeIdentifiers

/// What setup needs to show about a chosen file.
struct MediaInfo: Equatable {
    var size: CGSize
    var duration: Double
    var fps: Double
    var hasAudio: Bool
}

/// The app's state: connected displays, the show being edited, and facts about
/// each chosen file. SwiftUI redraws the setup window whenever a @Published
/// property changes. That's the OBSERVER PATTERN: the view subscribes to the
/// model instead of the model telling the view what to redraw.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var show = Show(machines: [Machine(name: AppModel.thisMac)]) {
        // [claude] P3b: a conductor's players must always have its latest
        // playlist, so every change is shared (coalesced, see scheduleShare).
        didSet {
            if mode == .conductor { scheduleShare() }
            scheduleAutosave()
        }
    }
    @Published private(set) var media: [String: MediaInfo] = [:]     // keyed by file path
    @Published private(set) var unreadable: Set<String> = []
    @Published private(set) var showPath: URL?
    @Published private(set) var isPlaying = false
    @Published var lastError: String?

    /// [claude] This Mac's computer name, which picks its part of the show
    /// (§ Show file › which machine). Read through SystemConfiguration rather
    /// than `Host.current().localizedName`, which can stall on a network name
    /// lookup; this is the name set in System Settings, read locally.
    static let thisMac = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName

    /// Which of the show's machines this Mac plays; nil = the show has no part for it.
    var machineIndex: Int? { show.machineIndex(named: Self.thisMac) }

    /// [claude] The name this Mac's screens are filed under in each work: its
    /// machine entry's name, which may be another Mac's name when a one-Mac
    /// show is opened somewhere else (§ Show file › which machine).
    var machineName: String? { machineIndex.map { show.machines[$0].name } }

    // MARK: Playlist (v4) [claude]

    /// The work whose panels setup is showing.
    @Published var selectedWork = 0

    /// Files a scan found but couldn't place (more files than displays), per
    /// work, for setup's warning. Not saved: the next scan finds them again.
    @Published private(set) var leftOver: [String: [String]] = [:]

    /// This Mac's media folder (§ v4 › Getting works in): a setting per Mac,
    /// like the mode, because each Mac holds its own files.
    /// [claude] P4b: found at launch (ShowFolder.pick) unless one was chosen
    /// by hand; only a folder chosen by hand is saved (see chooseMediaFolder),
    /// so a folder found by looking is looked for again next time.
    @Published var mediaFolder = ""
    private let mediaKey = "mediaFolder"
    /// Where the media folder came from, for setup ("next to the app", …).
    @Published private(set) var mediaSource = ""

    /// A panel's file as a full path: relative paths are inside the media folder.
    func resolve(_ file: String) -> String {
        file.hasPrefix("/") ? file : (mediaFolder as NSString).appendingPathComponent(file)
    }

    /// This Mac's panels for work `w`, one per display, in display order.
    func panels(of w: Int) -> [PanelConfig] {
        guard show.works.indices.contains(w), let name = machineName else { return [] }
        var ps = show.works[w].screens[name] ?? []
        while ps.count < designDisplays { ps.append(PanelConfig()) }      // [claude] the design, not just what's connected
        return ps
    }

    /// The selected work's panels on this Mac. Empty with no work or no part.
    var panels: [PanelConfig] { panels(of: selectedWork) }

    /// A two-way BINDING to one of the selected work's panels on this Mac,
    /// for setup's controls. The panels live in a dictionary inside an array
    /// inside the show, which SwiftUI's `$` paths can't reach through an
    /// optional key, so the get and set are written out here.
    func panelBinding(_ i: Int) -> Binding<PanelConfig> {
        Binding(get: { [weak self] in
            guard let self, i < self.panels.count else { return PanelConfig() }
            return self.panels[i]
        }, set: { [weak self] new in self?.setPanel(i, new) })
    }

    private func setPanel(_ i: Int, _ p: PanelConfig) {
        guard show.works.indices.contains(selectedWork), let name = machineName else { return }
        var ps = panels
        guard i < ps.count else { return }
        ps[i] = p
        show.works[selectedWork].screens[name] = ps
        // [claude] On a player the show is the conductor's: tell it, and it
        // records the change and shares it back (Mat, 2026-10-22). Only a
        // person's edit comes through here, never a show arriving, so the
        // echo can't loop.
        if mode == .player, linkUp {
            linkClient?.send(.setScreen(machine: name, work: show.works[selectedWork].name, index: i, panel: p))
        }
    }

    // MARK: Compose ahead (Mat, 2026-10-22) [claude]

    /// [claude] Step 2: parts no real Mac has taken yet: not this Mac, not a
    /// connected player, never reported.
    var unclaimedParts: [String] {
        let connected = Set(players.values.compactMap(\.machine))
        return show.machines.map(\.name).filter { $0 != machineName && !connected.contains($0) && reported[$0] == nil }
    }

    /// Connected players whose part wasn't recognised (they were added as
    /// Macs of their own), for "Played by ▾" on an unclaimed part.
    var unmatchedPlayers: [String] {
        let connected = Set(players.values.compactMap(\.machine))
        return joinedUnrecognised.filter { connected.contains($0) }.sorted()
    }

    /// Players this session added as Macs of their own, because no part was
    /// theirs by name or by files.
    @Published private(set) var joinedUnrecognised: Set<String> = []

    /// The fallback when files don't decide: player `player` plays `part`.
    /// The row the player was given on joining goes; the part takes its
    /// name; its report then fills any screens still empty.
    func assign(part: String, to player: String) {
        show = show.removingMachine(player).claimingMachine(part, as: player)
        joinedUnrecognised.remove(player)
        if let inv = reported[player] {
            show = SharedShow.merge(show, with: inv, conductor: Self.thisMac, addingNewWorks: false)
        }
        NSLog("link: %@ plays the part %@ (chosen by hand)", player, part)
    }

    /// When this Mac opens a show of several Macs with no part under its
    /// own name (a gallery Mac conducting from its kit), it takes the part
    /// its library's files match.
    private func claimOwnPart() {
        guard show.machines.count > 1, !show.machines.contains(where: { $0.name == Self.thisMac }) else { return }
        let connected = Set(players.values.compactMap(\.machine))
        let candidates = show.machines.map(\.name).filter { !connected.contains($0) }
        if let part = SharedShow.claim(show, files: Set(ownFiles), candidates: candidates) {
            NSLog("folder: this Mac takes the part %@ (by its files)", part)
            show = show.claimingMachine(part, as: Self.thisMac)
        }
    }

    /// What people call Mac `m` in setup and the preview: its label, else its name.
    func displayName(of m: String) -> String {
        show.machines.first { $0.name == m }?.displayName ?? m
    }

    /// A Mac that isn't here yet ("Gallery 2", 3 displays), added to the
    /// tableau after the others so a show can be composed in advance.
    func addMachine(label: String, displays: Int) {
        guard let s = show.addingMachine(label: label, displays: displays) else {
            lastError = "There's already a Mac called “\(label)” in this show (or the name is empty)."
            return
        }
        show = s
    }

    /// Takes a Mac out of the show, with its screens. Not this Mac, and not
    /// one that's connected now (it would only be added back).
    func removeMachine(_ m: String) {
        guard m != machineName, !isConnected(m) else { return }
        show = show.removingMachine(m)
    }

    /// The files a screen of Mac `m` can be set to: what that Mac reported
    /// or, for a Mac that hasn't (a Mac composed ahead), THIS Mac's library,
    /// whose paths are relative to Works/ and so resolve there too.
    func choosableFiles(for m: String) -> (files: [String], fromThisLibrary: Bool) {
        if m == machineName { return (ownFiles, true) }
        let reported = reportedFiles(of: m).map(\.path)
        return reported.isEmpty ? (ownFiles, true) : (reported, false)
    }

    /// [claude] Can this Mac edit machine `m`'s screens? The conductor and a
    /// standalone Mac: any. A player: its own, while the conductor is
    /// connected (offline edits would be overwritten by the next show).
    func canEditScreens(of m: String) -> Bool {
        switch mode {
        case .standalone, .conductor: return true
        case .player: return m == machineName && linkUp && sharedLengths != nil
        }
    }

    // MARK: Another Mac's screens, set from the conductor (v4 P4a) [claude]

    // § Getting works in › Manual: "a player's screen is chosen from the
    // files that player reported, without visiting it". Since interface
    // step 1 every Mac's screens are on the tableau map at once, so there is
    // no "whose screens" selection any more.

    /// Machine `m`'s panels for the selected work, one per display it has
    /// (as it last reported, or as saved).
    func panels(on m: String) -> [PanelConfig] {
        guard show.works.indices.contains(selectedWork) else { return [] }
        let count = show.machines.first(where: { $0.name == m })?.screenCount ?? 0
        var ps = show.works[selectedWork].screens[m] ?? []
        while ps.count < count { ps.append(PanelConfig()) }
        return ps
    }

    /// The same BINDING idea as `panelBinding`, for another Mac. Writing
    /// changes the show, and the show's didSet shares it with the players.
    func panelBinding(on m: String, _ i: Int) -> Binding<PanelConfig> {
        Binding(get: { [weak self] in
            guard let self else { return PanelConfig() }
            let ps = self.panels(on: m)
            return i < ps.count ? ps[i] : PanelConfig()
        }, set: { [weak self] new in
            guard let self, self.show.works.indices.contains(self.selectedWork) else { return }
            var ps = self.panels(on: m)
            guard i < ps.count else { return }
            ps[i] = new
            self.show.works[self.selectedWork].screens[m] = ps
            // [claude] Compose ahead: measure a file chosen for a Mac that
            // isn't here, so the work's length counts it.
            if let f = new.file.map(self.resolve), self.fileExists(f) { self.loadInfo(f) }
        })
    }

    /// What machine `m` last reported this session, connected now or not.
    func inventory(of m: String) -> Inventory? { reported[m] }

    func isConnected(_ m: String) -> Bool { players.values.contains { $0.machine == m } }

    /// Every video machine `m` reported, as the path a panel stores
    /// ("Folder/file", relative to that Mac's media folder), in folder then
    /// name order: the choices for its screens.
    func reportedFiles(of m: String) -> [(path: String, file: InventoryFile)] {
        guard let inv = inventory(of: m) else { return [] }
        return inv.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.flatMap { folder in
            inv.folders[folder, default: []]
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { ("\(folder)/\($0.name)", $0) }
        }
    }

    /// [claude] The tableau screen number of this Mac's display 1, for files
    /// named "_N" (Mat, 2026-10-22): 1 unless Macs come before it in the show.
    var firstScreen: Int { machineName.map { SharedShow.firstScreen(show, of: $0) } ?? 1 }

    /// One play of work `w` on this Mac's own files: its longest file here.
    func ownLength(of w: Int) -> Double {
        panels(of: w).prefix(designDisplays).compactMap { $0.file.flatMap { media[resolve($0)]?.duration } }.max() ?? 0
    }

    /// One play of work `w` (§ v4 › Playing): its longest file on ANY Mac.
    /// [claude] P3b: every Mac must time the playlist by the same numbers,
    /// so a conductor takes the longest across its own files and every
    /// player's inventory, and a player uses exactly what the conductor sent.
    func length(of w: Int) -> Double {
        switch mode {
        case .standalone: return max(ownLength(of: w), aheadLength(of: w))
        case .conductor:
            guard show.works.indices.contains(w) else { return 0 }
            return max(ownLength(of: w), aheadLength(of: w), PlaylistMerge.length(of: show.works[w], in: Array(reported.values)))
        case .player:
            guard let lengths = sharedLengths, lengths.indices.contains(w) else { return ownLength(of: w) }
            return lengths[w]
        }
    }

    func addWork() {
        show.works.append(Work(name: "Work \(show.works.count + 1)"))
        selectedWork = show.works.count - 1
    }

    func removeWork(_ w: Int) {
        guard show.works.indices.contains(w) else { return }
        show.works.remove(at: w)
        selectedWork = min(selectedWork, max(show.works.count - 1, 0))
    }

    func moveWork(_ w: Int, by step: Int) {
        let to = w + step
        guard show.works.indices.contains(w), show.works.indices.contains(to) else { return }
        show.works.swapAt(w, to)
        selectedWork = to
    }

    func chooseMediaFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        useLibrary(url.path)           // [claude] P4d: a library, or a folder of works
        mediaSource = "chosen by hand"
        UserDefaults.standard.set(url.path, forKey: mediaKey)
    }

    // MARK: Zero setup (v4 P4b) [claude]

    /// The folder this app is in, as the person put it there. A quarantined
    /// app (downloaded, AirDropped) opened where it was unzipped is run by
    /// macOS from a hidden read-only copy (APP TRANSLOCATION), so its own
    /// path says nothing about the folder it came in. Security.framework can
    /// give the original path; the function isn't in the public headers, so
    /// it is looked up at run time, and if that fails the app's folder is
    /// simply not used (the other places are still searched).
    static var appFolder: String? {
        var url = Bundle.main.bundleURL
        if url.path.contains("/AppTranslocation/") {
            typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
            guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
                  let sym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL"),
                  let original = unsafeBitCast(sym, to: Original.self)(url as CFURL, nil)?.takeRetainedValue() as URL? else {
                NSLog("folder: app is translocated and its original folder couldn't be found")
                return nil
            }
            url = original
        }
        return url.deletingLastPathComponent().path
    }

    /// A folder's files and its subfolders' listings, or nil if it isn't a folder.
    private static func listing(_ path: String) -> (files: [String], subfolders: [String: [String]])? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        var files: [String] = [], subs: [String: [String]] = [:]
        for n in names {
            let p = (path as NSString).appendingPathComponent(n)
            var d: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &d), d.boolValue, !n.hasSuffix(".app") {
                subs[n] = (try? fm.contentsOfDirectory(atPath: p)) ?? []
            } else {
                files.append(n)
            }
        }
        return (files, subs)
    }

    /// Show files in the media folder, with their dates.
    private func folderShows() -> [(path: String, modified: Double)] {
        guard !showsFolder.isEmpty, let l = Self.listing(showsFolder) else { return [] }
        return ShowFolder.shows(in: l.files).map { name in
            let p = (showsFolder as NSString).appendingPathComponent(name)
            let d = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? nil
            return (p, d?.timeIntervalSince1970 ?? 0)
        }
    }

    // MARK: The library: works pool and shows (v4 P4d) [claude]

    /// The library's root (what the search found or Choose… picked), and
    /// where its show files live. `mediaFolder` is its works pool: with a
    /// `Works/` folder, that; otherwise the root itself (§ Library).
    @Published private(set) var libraryFolder = ""
    @Published private(set) var showsFolder = ""
    /// The show files in the library, for the show menu.
    @Published private(set) var showFiles: [String] = []
    /// This Mac's work folders (with videos), for the pool.
    @Published private(set) var ownWorks: [String] = []
    /// True when this launch created the library (none existed): setup says
    /// where, so the person knows where to put works.
    @Published private(set) var libraryCreated = false

    func revealLibrary() {
        guard !libraryFolder.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mediaFolder)])
    }

    /// True for the unsaved all-works show made when a library has no show:
    /// only that show grows by itself when works appear (Scan, a player's
    /// report). A saved show is curated and changes only by hand.
    @Published private(set) var autoShow = false

    /// Point the app at library `root`: its works pool and shows folder.
    private func useLibrary(_ root: String) {
        libraryFolder = root
        let layout = root.isEmpty ? (works: "", shows: "")
            : ShowFolder.layout(root: root, subfolders: Array((Self.listing(root)?.subfolders ?? [:]).keys))
        mediaFolder = layout.works
        showsFolder = layout.shows
        refreshLibrary()
    }

    /// Re-read the show files and this Mac's work folders.
    func refreshLibrary() {
        showFiles = folderShows().map(\.path).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        ownWorks = Self.listing(mediaFolder).map { l in
            l.subfolders.filter { !FolderScan.videos($0.value).isEmpty }.map(\.key)
        } ?? []
    }

    /// Every work in the pool: this Mac's and every player's (reported).
    var libraryWorks: [String] { ShowFolder.pool(own: ownWorks, inventories: Array(reported.values)) }

    /// Pool works the current show doesn't have: "Add from library".
    var worksToAdd: [String] {
        let inShow = Set(show.works.map(\.name))
        return libraryWorks.filter { !inShow.contains($0) }
    }

    var showName: String {
        showPath?.deletingPathExtension().lastPathComponent ?? (autoShow ? "All works (not saved)" : "Untitled")
    }

    /// Adds pool work `name` to the show, with screens on every Mac that has
    /// it: this Mac's from its folder, each player's from its report.
    func addFromLibrary(_ name: String) {
        guard !show.works.contains(where: { $0.name == name }) else { return }
        show.works.append(Work(name: name))
        selectedWork = show.works.count - 1
        refillScreens()
    }

    func addAllFromLibrary() { worksToAdd.forEach(addFromLibrary) }

    /// Gives the show's works screens on every Mac that has their files and
    /// no screens set yet. Never adds works.
    private func refillScreens() {
        let auto = autoShow
        autoShow = false
        scan()
        for inv in reported.values {
            show = SharedShow.merge(show, with: inv, conductor: Self.thisMac, addingNewWorks: false)
        }
        autoShow = auto
    }

    /// "New show…": every work in the pool, in name order (Mat: what Scan
    /// gives today), saved into the library's shows folder; then curate.
    // MARK: Autosave (Mat, 2026-10-22) [claude]

    private var autosaveTimer: Timer?
    /// The all-works show as the app last built it (scan, a player's works).
    /// If the show now differs, a person edited it, and switching away asks
    /// before the edits are lost. Comparing with a BASELINE, rather than
    /// flagging edits, catches every kind of edit without listing them.
    private var autoBaseline: Show?
    private var autoShowEdited: Bool {
        get { autoShow && autoBaseline.map { $0 != show } == true }
        set { if !newValue { autoBaseline = show } }
    }
    /// Set while the show is being REPLACED (open, New show, a player
    /// receiving): no autosave of a show mid-replacement.
    private var replacingShow = false

    /// After the app itself changed the all-works show: that's the baseline.
    private func markAutoBaseline() { if autoShow { autoBaseline = show } }

    /// A named show saves itself about a second after the last change
    /// (DEBOUNCED: a burst of edits is one write). The write reads the show
    /// and its path when it FIRES, not when it was asked for, so a show
    /// replaced meanwhile can never be written into another show's file.
    private func scheduleAutosave() {
        guard showPath != nil, !autoShow, mode != .player, !replacingShow else { return }
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushAutosave() }
        }
    }

    /// Writes a pending autosave now: before the show is replaced and when
    /// the app quits, so an edit made just before isn't lost.
    func flushAutosave() {
        guard let timer = autosaveTimer else { return }
        timer.invalidate()
        autosaveTimer = nil
        guard let url = showPath, !autoShow, mode != .player else { return }
        do {
            try ShowFile.encode(show).write(to: url)
            NSLog("autosave: %@", url.lastPathComponent)
        } catch {
            lastError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Before leaving the edited all-works show: Save… / Discard / Cancel.
    /// Returns false if the person cancelled.
    private func confirmLeavingAutoShow() -> Bool {
        guard autoShow, autoShowEdited else { return true }
        let a = NSAlert()
        a.messageText = "Save the changes to “All works”?"
        a.informativeText = "It hasn't been saved as a show yet. Without saving, these changes are lost."
        a.addButton(withTitle: "Save…")
        a.addButton(withTitle: "Don't Save")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: saveDialog(); return !autoShow       // saved = no longer the auto show
        case .alertSecondButtonReturn: autoShowEdited = false; return true
        default: return false
        }
    }

    func newShow() {
        flushAutosave()
        guard confirmLeavingAutoShow() else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: Self.showExtension) ?? .json]
        if !showsFolder.isEmpty {
            try? FileManager.default.createDirectory(atPath: showsFolder, withIntermediateDirectories: true)
            p.directoryURL = URL(fileURLWithPath: showsFolder)
        }
        p.nameFieldStringValue = "New show.\(Self.showExtension)"
        guard p.runModal() == .OK, let url = p.url else { return }
        if isPlaying { stop() }
        replacingShow = true
        // Same Macs and settings, fresh playlist: the installation is the same.
        show = Show(machines: show.machines, playlist: show.playlist, sync: show.sync)
        autoShow = true
        sizeThisMacByWorks()
        scan()
        for inv in reported.values { show = SharedShow.merge(show, with: inv, conductor: Self.thisMac) }
        autoShow = false
        selectedWork = 0
        save(to: url)
        replacingShow = false
    }

    /// Launch: find the media folder, open the show, pick the role
    /// (§ v4 › Zero setup). Runs once, from init, before the clock starts.
    private func findEverything() {
        let chosen = UserDefaults.standard.string(forKey: mediaKey)
        let app = Self.appFolder
        var root = ShowFolder.pick(chosen: chosen, appFolder: app, home: NSHomeDirectory(), listing: Self.listing) ?? ""
        // [claude] No library anywhere (a fresh Mac): make one, in Movies
        // (Mat, 2026-10-22), so there is somewhere obvious to put works.
        if root.isEmpty {
            let made = ShowFolder.defaultLibrary(home: NSHomeDirectory())
            do {
                for sub in [ShowFolder.worksName, ShowFolder.showsName] {
                    try FileManager.default.createDirectory(atPath: (made as NSString).appendingPathComponent(sub),
                                                            withIntermediateDirectories: true)
                }
                root = made
                libraryCreated = true
            } catch {
                NSLog("folder: couldn't create %@: %@", made, "\(error)")
            }
        }
        useLibrary(root)
        mediaSource = root.isEmpty ? ""
            : libraryCreated ? "created by tableauX"
            : root == chosen ? "chosen by hand"
            : root == app ? "the folder tableauX is in"
            : "found by name"
        NSLog("folder: %@ (%@); works in %@", root.isEmpty ? "none found" : root, mediaSource, mediaFolder)

        let shows = folderShows()
        if let path = ShowFolder.showToOpen(last: UserDefaults.standard.string(forKey: lastShowKey),
                                            folder: showsFolder.isEmpty ? nil : showsFolder,
                                            folderChosen: root == chosen, folderShows: shows),
           FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        }

        // The role. A mode saved by a build before P4b counts as chosen by
        // hand, so updating never flips a Mac's role behind someone's back.
        let d = UserDefaults.standard
        if d.object(forKey: modeByHandKey) == nil, d.string(forKey: modeKey) != nil { d.set(true, forKey: modeByHandKey) }
        if d.bool(forKey: modeByHandKey), let saved = d.string(forKey: modeKey).flatMap(Mode.init) {
            mode = saved
        } else {
            // The folder decides (Mat): show files = Conductor; works but no
            // show = Player; an empty library or none = Standalone.
            switch ShowFolder.role(shows: shows.count, works: ownWorks.count) {
            case .conductor: mode = .conductor
            case .player: mode = .player
            case .standalone: mode = .standalone
            }
            NSLog("folder: role %@, from the folder", mode.rawValue)
        }
        // No show opened (a fresh library): the all-works show, unsaved, so
        // a folder of works plays without any setup (§ Library).
        if mode != .player, showPath == nil, show.works.isEmpty, !mediaFolder.isEmpty {
            autoShow = true
            sizeThisMacByWorks()
            scan()
        }
    }

    /// Scans the media folder: each subfolder is a work, its videos go on
    /// this Mac's displays in name order (FolderScan), merged into the
    /// playlist so works already set up keep their settings (PlaylistMerge).
    /// Only the listing is read here; durations load in the background.
    func scan() {
        // [claude] P3b: a player's works come from the conductor, so its
        // Scan sends a fresh inventory, which the conductor folds in.
        if mode == .player { sentInventory = nil; refreshInventory(); return }
        guard !mediaFolder.isEmpty, let name = machineName else { return }
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: mediaFolder) else {
            lastError = "Couldn't read the media folder \(mediaFolder)."
            return
        }
        var inventory: [String: [InventoryFile]] = [:]
        var left: [String: [String]] = [:]
        for folder in folders where !folder.hasPrefix(".") {
            let path = (mediaFolder as NSString).appendingPathComponent(folder)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  let files = try? fm.contentsOfDirectory(atPath: path) else { continue }
            let videos = FolderScan.videos(files)
            guard !videos.isEmpty else { continue }
            // Durations aren't known yet; the merge only needs the names.
            inventory[folder] = videos.map { InventoryFile(name: $0, duration: 0) }
            let extra = FolderScan.assign(folder: folder, files: videos, displays: designDisplays, firstScreen: firstScreen).leftOver
            if !extra.isEmpty { left[folder] = extra }
        }
        // [claude] P4d: only the unsaved all-works show gains works here; a
        // saved show is curated, and new folders wait in the library pool.
        let merged = PlaylistMerge.merge(show.works, with: [Inventory(machine: name, displays: designDisplays, folders: inventory)],
                                         firstScreens: [name: firstScreen], addingNewWorks: autoShow)
        // [claude] Only assign when something changed: rescans run every few
        // seconds, and every assignment would otherwise trigger an autosave.
        if merged != show.works { show.works = merged }
        let inShow = Set(show.works.map(\.name))
        if left.filter({ inShow.contains($0.key) }) != leftOver { leftOver = left.filter { inShow.contains($0.key) } }
        let before = Set(ownWorks)
        refreshLibrary()
        let added = Set(ownWorks).subtracting(before).subtracting(inShow)
        if !before.isEmpty, !added.isEmpty {
            libraryNote = "\(added.count) new work\(added.count == 1 ? "" : "s") in the library: \(added.sorted().joined(separator: ", ")). Add from library to use \(added.count == 1 ? "it" : "them")."
        }
        fillNewDisplays()
        loadAllInfo()
    }

    /// [claude] Interface step 1: something the automatic rescan found, said
    /// once in the status line ("2 new works in the library…").
    @Published var libraryNote: String?

    /// Re-reads the library without anyone pressing Scan (Mat: "when I've
    /// hit the scan button it's not done anything"): when the app becomes
    /// active and every 5 s. Not while playing: a show on screen isn't
    /// edited underneath itself.
    private func rescan() {
        guard !isPlaying, mode != .player, !mediaFolder.isEmpty else { return }
        scan()
    }

    /// Every video in this Mac's library, as a panel stores it
    /// ("Work/file.mov"), for the tableau map's file menu.
    var ownFiles: [String] {
        guard let l = Self.listing(mediaFolder) else { return [] }
        return l.subfolders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.flatMap { folder in
            FolderScan.videos(l.subfolders[folder] ?? []).map { "\(folder)/\($0)" }
        }
    }

    /// [claude] Gives each work's unset displays its folder's unused videos
    /// (FolderScan.fill; Mat, 2026-10-21), so a display plugged in after the
    /// scan, or a show opened on a Mac with more displays, isn't left black
    /// while files sit unused. Also brings the left-over warnings up to date.
    ///
    /// A work's folder is the one folder its files on this Mac are in (a
    /// media folder subfolder, or an imported folder); with no files yet,
    /// `<media folder>/<work name>`. Files from several folders mean the
    /// work was set by hand, so it is left alone.
    private func fillNewDisplays() {
        guard let name = machineName else { return }
        for w in show.works.indices {
            let set = show.works[w].screens[name] ?? []
            guard let folder = FolderScan.folder(of: set, work: show.works[w].name),
                  folder.hasPrefix("/") || !mediaFolder.isEmpty,
                  let files = try? FileManager.default.contentsOfDirectory(atPath: resolve(folder)) else { continue }
            let (panels, left) = FolderScan.fill(set, folder: folder, files: files, displays: designDisplays, firstScreen: firstScreen)
            if panels != set {
                show.works[w].screens[name] = panels
                NSLog("fill: %@ now on %d display(s)", show.works[w].name, panels.count)
            }
            leftOver[show.works[w].name] = left.isEmpty ? nil : left
        }
        markAutoBaseline()          // [claude] the app's change, not a person's
    }

    /// Reads the length etc. of every file this Mac plays, in every work.
    private func loadAllInfo() {
        for w in show.works.indices {
            panels(of: w).compactMap(\.file).map(resolve).filter(fileExists).forEach(loadInfo)
            aheadFiles(of: w).forEach(loadInfo)
        }
    }

    /// [claude] Compose ahead: the files of Macs that haven't reported (not
    /// here yet), as found in THIS Mac's library, so a work's length counts
    /// their screens too. Once a Mac reports, its own report counts instead.
    private func aheadFiles(of w: Int) -> [String] {
        guard show.works.indices.contains(w), mode != .player else { return [] }
        return show.machines.filter { $0.name != machineName && reported[$0.name] == nil }.flatMap { m in
            (show.works[w].screens[m.name] ?? []).prefix(m.displays).compactMap(\.file).map(resolve).filter(fileExists)
        }
    }

    private func aheadLength(of w: Int) -> Double {
        aheadFiles(of: w).compactMap { media[$0]?.duration }.max() ?? 0
    }

    // MARK: Collect and import (§ v4 › Collecting and importing) [claude]

    /// One line of collect progress for setup; nil when no collect is running.
    @Published private(set) var collecting: String?

    /// Adds the works in a folder chosen from anywhere, LINKED IN PLACE (Mat):
    /// full paths to the files where they are, nothing copied.
    func importFolder() {
        guard let name = machineName else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.prompt = "Import"
        guard p.runModal() == .OK, let url = p.url else { return }
        let fm = FileManager.default
        guard let listing = try? fm.contentsOfDirectory(atPath: url.path) else {
            lastError = "Couldn't read \(url.path)."
            return
        }
        var files: [String] = [], subfolders: [String: [String]] = [:]
        for item in listing {
            let path = url.appendingPathComponent(item).path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                subfolders[item] = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            } else {
                files.append(item)
            }
        }
        let r = FolderImport.works(root: url.path, rootFiles: files, subfolders: subfolders, machine: name,
                                   displays: designDisplays, existing: Set(show.works.map(\.name)), firstScreen: firstScreen)
        show.works += r.works
        leftOver.merge(r.leftOver) { $1 }
        if !r.works.isEmpty { selectedWork = show.works.count - r.works.count }
        lastError = r.works.isEmpty && r.skipped.isEmpty ? "No video files in \(url.lastPathComponent) or the folders inside it."
            : r.skipped.isEmpty ? nil
            : "Already in the playlist, so not imported: \(r.skipped.joined(separator: ", "))."
        NSLog("import: %d work(s) from %@", r.works.count, url.path)
        loadAllInfo()
    }

    /// Copies this Mac's files for the whole show into a new folder named
    /// after the show, with the show file rewritten to point at the copies.
    /// [claude] Export: a copy of the show as a library of its own (Works/ +
    /// Shows/) somewhere else, to archive or hand on (Mat's 21 Oct request).
    /// It was "Collect show" until Mat's review (2026-10-22); Collect now
    /// gathers into THIS library instead (collectShow).
    func exportShow() {
        let showName = showPath?.deletingPathExtension().lastPathComponent ?? "Untitled"
        guard let dir = chooseCollectFolder() else { return }
        let root = dir.appendingPathComponent(Collect.uniqueName(showName, taken: Self.namesIn(dir)))
        collect(Array(show.works.indices), into: root, worksIn: ShowFolder.worksName,
                showFile: "\(ShowFolder.showsName)/\(showName).\(Self.showExtension)")
    }

    /// Collect the show: bring its files that live outside this library into
    /// Works/ (Mat, 2026-10-22). Nothing already in the library is copied.
    func collectShow() { gather(Array(show.works.indices)) }

    /// The same for one work.
    func collectWork(_ w: Int) {
        guard show.works.indices.contains(w) else { return }
        gather([w])
    }

    /// Plans with Collect.gather (pure), copies off the main thread, then
    /// points the show's screens at the copies (and autosave keeps that).
    private func gather(_ indices: [Int]) {
        guard collecting == nil, let name = machineName, !mediaFolder.isEmpty else { return }
        let works = indices.map { show.works[$0] }
        let folders = Self.listing(mediaFolder)?.subfolders ?? [:]
        let plan = Collect.gather(works: works, machine: name, worksFolder: mediaFolder,
                                  folders: Set(folders.keys), listing: { folders[$0] ?? [] })
        let copies = plan.copies.filter { fileExists($0.source) }
        let missing = plan.copies.count - copies.count
        guard !copies.isEmpty else {
            libraryNote = missing > 0 ? "\(missing) linked file(s) can't be found, so nothing was collected."
                                      : "Everything this \(indices.count == 1 ? "work" : "show") uses is already in the library."
            return
        }
        let fm = FileManager.default
        let bytes = copies.reduce(Int64(0)) { $0 + ((try? fm.attributesOfItem(atPath: $1.source)[.size] as? Int64) ?? 0) }
        let root = URL(fileURLWithPath: mediaFolder)
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if bytes > free {
            lastError = "Not enough space: collecting needs \(Self.gigabytes(bytes)), the library's disk has \(Self.gigabytes(free)) free."
            return
        }
        collecting = "Collecting 0 of \(copies.count) files…"
        NSLog("collect: %d file(s), %@ into the library", copies.count, Self.gigabytes(bytes))
        Task.detached {
            let fm = FileManager.default
            var failure: String?
            do {
                for (n, c) in copies.enumerated() {
                    let dest = root.appendingPathComponent(c.dest)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(atPath: c.source, toPath: dest.path)
                    await MainActor.run { self.collecting = "Collecting \(n + 1) of \(copies.count) files…" }
                }
            } catch {
                failure = "Collecting stopped: \(error.localizedDescription). The show still uses the original files."
            }
            await MainActor.run { [failure] in
                self.collecting = nil
                if let failure { self.lastError = failure; return }
                // Point the screens at the copies, by work name (the show
                // may have been reordered while copying).
                for w in plan.works {
                    guard let i = self.show.works.firstIndex(where: { $0.name == w.name }) else { continue }
                    self.show.works[i].screens[name] = w.screens[name]
                }
                self.libraryNote = "Collected \(copies.count) file(s) into the library" + (missing > 0 ? "; \(missing) couldn't be found." : ".")
                NSLog("collect: done")
                self.refreshLibrary()
                self.loadAllInfo()
            }
        }
    }

    private func chooseCollectFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "Collect Here"
        p.message = "Choose where to put the collected files. The originals are left where they are."
        return p.runModal() == .OK ? p.url : nil
    }

    private static func namesIn(_ dir: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
    }

    /// Plans the copies (PlayerCore's Collect, a pure function), checks them
    /// against the disk, then copies OFF THE MAIN THREAD: gigabytes of video
    /// take minutes, and the setup window must keep redrawing meanwhile.
    private func collect(_ indices: [Int], into root: URL, worksIn: String? = nil, showFile: String?) {
        guard collecting == nil, let name = machineName else { return }
        let plan = Collect.plan(works: indices.map { show.works[$0] }, machine: name, resolve: resolve,
                                takenFolders: Self.namesIn(root), firstScreen: firstScreen)
        let fm = FileManager.default
        let missing = plan.copies.filter { !fileExists($0.source) }
        let copies = plan.copies.filter { fileExists($0.source) }
        // Check the space BEFORE copying: running out half way would leave a
        // half-made archive and a full disk, on a Mac that may be mid-show.
        let bytes = copies.reduce(Int64(0)) { $0 + ((try? fm.attributesOfItem(atPath: $1.source)[.size] as? Int64) ?? 0) }
        let free = (try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if bytes > free {
            lastError = "Not enough space: collecting needs \(Self.gigabytes(bytes)), the disk has \(Self.gigabytes(free)) free."
            return
        }
        var archived = show
        archived.works = plan.works
        let showData = showFile == nil ? nil : try? ShowFile.encode(archived)
        collecting = "Collecting 0 of \(copies.count) files…"
        NSLog("collect: %d file(s), %@ into %@", copies.count, Self.gigabytes(bytes), root.path)
        Task.detached {
            let fm = FileManager.default
            var failure: String?
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                for (n, c) in copies.enumerated() {
                    let dest = (worksIn.map { root.appendingPathComponent($0) } ?? root).appendingPathComponent(c.dest)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(atPath: c.source, toPath: dest.path)
                    await MainActor.run { self.collecting = "Collecting \(n + 1) of \(copies.count) files…" }
                }
                if let showFile, let showData {
                    let url = root.appendingPathComponent(showFile)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try showData.write(to: url)
                }
            } catch {
                failure = "Collecting stopped: \(error.localizedDescription) The files copied so far are in \(root.path)."
            }
            await MainActor.run { [failure] in
                self.collecting = nil
                self.lastError = failure ?? (missing.isEmpty ? nil
                    : "Collected into \(root.path), except \(missing.count) file(s) not found: "
                      + missing.map(\.source).joined(separator: ", ") + ".")
                NSLog("collect: %@", failure ?? "done")
                if failure == nil { NSWorkspace.shared.activateFileViewerSelecting([root]) }
            }
        }
    }

    private static func gigabytes(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }

    private var playback: Playback?
    private let lastShowKey = "lastShowPath"
    private var hasLaunched = false

    // MARK: Network mode (v3) [claude]

    /// v3 § One app, three modes. Stored per Mac, not in the show: it says what
    /// this machine is, and the same show can be opened in any mode.
    enum Mode: String, CaseIterable, Identifiable {
        case standalone, conductor, player
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @Published var mode: Mode = .standalone {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
            // [claude] P4b: a change after launch is a person choosing; from
            // then on the folder no longer decides this Mac's role.
            if clockReady { UserDefaults.standard.set(true, forKey: modeByHandKey); restartClock() }
        }
    }
    private let modeByHandKey = "modeChosenByHand"
    /// False until init has restored the saved mode. Without it, restoring the
    /// mode in init started the clock once from `didSet` and again from init's
    /// own call (observed 2026-10-21: the second bind found the port taken).
    private var clockReady = false
    /// The conductor's address, as typed. Applied by `restartClock()` (setup
    /// calls it when the field is submitted), not on every keystroke.
    @Published var conductorAddress = "" {
        didSet { UserDefaults.standard.set(conductorAddress, forKey: addressKey) }
    }
    /// One line about the clock for setup (§ v3 › Clock, What setup shows).
    @Published private(set) var clockStatus = ""

    private let modeKey = "networkMode", addressKey = "conductorAddress"
    private var server: ClockServer?
    private var client: ClockClient?
    private var statusTimer: Timer?
    private var statusTicks = 0

    init() {
        refreshDisplays()
        // Re-read displays whenever one is plugged in, unplugged or rearranged.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // [claude] Only what needs no disk happens here. The library search
        // (which may wake a sleeping drive) waits until the window is on
        // screen and can say what it's doing: see launched() (Mat,
        // 2026-10-22: "we need an indicator as it's launching").
        conductorAddress = UserDefaults.standard.string(forKey: addressKey) ?? ""
        // [claude] Autosave: an edit made in the last second is written on quit.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }     // back from Finder: pick up what changed
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushAutosave() }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClockStatus() }
        }
    }

    /// Stops whatever clock component is running and starts the one the mode
    /// asks for. One place that owns the transition, so there is never a
    /// server and a client at once, or a socket left open from the last mode.
    func restartClock() {
        // A show running on the old clock can't carry on with a new one.
        if isPlaying { stop() }
        server?.stop(); server = nil
        client?.stop(); client = nil
        stopLink()
        defer { startLink() }       // [claude] P3b: the link follows the mode, as the clock does
        follower = StateFollower()
        dismissedVersion = nil
        do {
            switch mode {
            case .standalone: break
            case .conductor: server = try ClockServer()
            case .player:
                // [claude] P4b: with no address typed, the link finds the
                // conductor by Bonjour and starts the clock on it (linkConnected).
                let address = conductorAddress.trimmingCharacters(in: .whitespaces)
                if !address.isEmpty { try startClockClient(address) }
            }
        } catch {
            clockStatus = "Clock: \(error)"
            NSLog("clock: %@", "\(error)")
            return
        }
        NSLog("clock: mode %@", mode.rawValue)
        updateClockStatus()
    }

    private func startClockClient(_ address: String) throws {
        // States arrive on the clock's receive thread; hop to the main
        // actor, which owns playback.
        client = try ClockClient(conductor: address) { [weak self] s in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(s) } }
        }
    }

    /// [claude] P4b: the conductor found by Bonjour (nil = none yet, or an
    /// address was typed), and the names seen when there are several.
    @Published private(set) var foundConductor: (name: String, ipv4: String)?
    @Published private(set) var severalConductors: [String] = []

    /// Once a second: refresh the status line; every 10 s, also log it, so a
    /// long run can be read back afterwards with `log show`.
    // MARK: Following the conductor (v3 § Show state) [claude]

    private var follower = StateFollower()
    /// The state a person stopped this player during (Esc). It isn't
    /// restarted until the conductor's state changes, or Esc would be undone
    /// by the next once-a-second repeat.
    private var dismissedVersion: UInt64?
    private var refusedVersion: UInt64?

    private func received(_ s: ShowState) {
        guard follower.accept(s, now: Double(hostNanos()) / 1e9) else { return }
        reconcile()
    }

    /// Bring this player into line with the conductor's latest state. Called
    /// for every state received, including the once-a-second repeats, so
    /// every branch must be a no-op when nothing has changed.
    private func reconcile() {
        guard mode == .player, let s = follower.current else { return }
        switch s.phase {
        case .stopped:
            dismissedVersion = nil
            if isPlaying { NSLog("follow: conductor stopped"); stop() }
        case .playing, .paused:
            if let playback {
                // [claude] The conductor switched between preview and
                // present: stop this kind and start the other at once.
                if playback.isPreview != s.preview {
                    switchingKind = true
                    stop()
                    switchingKind = false
                    if s.preview { previewFollowing(s) } else { startPlayback(following: s) }
                    return
                }
                playback.follow(s)
            } else if s.phase == .playing, s.version != dismissedVersion {
                // [claude] Networked preview: the conductor's preview opens
                // this Mac's own preview (Mat, 2026-10-22).
                if s.preview { previewFollowing(s) } else { startPlayback(following: s) }
            }
        }
    }

    /// Set while switching between preview and present on a player, so the
    /// stop in between isn't taken for a person's Esc.
    private var switchingKind = false

    // MARK: The link: one playlist for every Mac (v4 P3b) [claude]

    /// What the conductor knows about one connected player.
    struct PlayerLink {
        var machine: String?
        var build: String?
        var inventory: Inventory?
        var blocking: [String]?          // nil = hasn't reported yet
    }

    /// Conductor: every player connected over the link, by connection.
    @Published private(set) var players: [ObjectIdentifier: PlayerLink] = [:]
    /// Conductor: each Mac's last inventory, KEPT when it disconnects. Work
    /// lengths come from these, so a player dropping off Wi-Fi doesn't
    /// change the timeline under the others, and its files stay choosable
    /// in setup (P4a).
    @Published private(set) var reported: [String: Inventory] = [:]
    /// Player: the conductor's work lengths; nil until its playlist arrives.
    @Published private(set) var sharedLengths: [Double]?
    @Published private(set) var linkUp = false
    private var linkServer: LinkServer?
    private var linkClient: LinkClient?
    private var shareScheduled = false
    private var sentInventory: Inventory?
    private var sentReport: [String]?
    /// Player: each media file's size and date when last measured, so a
    /// file replaced under the same name is measured again.
    private var stamps: [String: (Int64, Double)] = [:]

    static let build = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    private func startLink() {
        switch mode {
        case .standalone: break
        case .conductor:
            do {
                linkServer = try LinkServer(
                    advertiseAs: Self.thisMac,
                    onMessage: { [weak self] m, id in DispatchQueue.main.async { MainActor.assumeIsolated { self?.conductorReceived(m, from: id) } } },
                    onClose: { [weak self] id in DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.players.removeValue(forKey: id) } } })
            } catch {
                clockStatus = "Link: couldn't listen on TCP port \(Link.port): \(error)"
            }
        case .player:
            // [claude] P4b: no address typed = find the conductor by Bonjour.
            let address = conductorAddress.trimmingCharacters(in: .whitespaces)
            linkClient = LinkClient(
                conductor: address.isEmpty ? nil : address,
                onConnected: { [weak self] name, ip in DispatchQueue.main.async { MainActor.assumeIsolated { self?.linkConnected(name: name, ipv4: ip) } } },
                onMessage: { [weak self] m in DispatchQueue.main.async { MainActor.assumeIsolated { self?.playerReceived(m) } } },
                onDisconnected: { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.linkUp = false } } },
                onSeveral: { [weak self] names in DispatchQueue.main.async { MainActor.assumeIsolated { self?.severalConductors = names } } })
        }
    }

    private func stopLink() {
        linkServer?.stop(); linkServer = nil
        linkClient?.stop(); linkClient = nil
        players = [:]
        reported = [:]
        sharedLengths = nil
        linkUp = false
        foundConductor = nil
        severalConductors = []
    }

    // Conductor side.

    private func conductorReceived(_ m: LinkMessage, from id: ObjectIdentifier) {
        guard mode == .conductor else { return }
        switch m {
        case .hello(let machine, let build):
            players[id] = PlayerLink(machine: machine, build: build)
            NSLog("link: hello from %@ (build %@)", machine, build)
            shareShow(to: id)
        case .inventory(let inv):
            players[id, default: PlayerLink()].machine = inv.machine
            players[id]?.inventory = inv
            reported[inv.machine] = inv
            NSLog("link: inventory from %@: %d folder(s), %d display(s)", inv.machine, inv.folders.count, inv.displays)
            // [claude] Compose ahead, step 2: a Mac the show doesn't know by
            // name takes the part composed for it, judged by its files.
            if !show.machines.contains(where: { $0.name == inv.machine }) {
                if let part = SharedShow.claim(show, files: SharedShow.files(of: inv), candidates: unclaimedParts) {
                    NSLog("link: %@ takes the part %@ (by its files)", inv.machine, part)
                    show = show.claimingMachine(part, as: inv.machine)
                } else {
                    joinedUnrecognised.insert(inv.machine)       // "Played by…" can place it
                }
            }
            // Folding it in changes the show, whose didSet shares it again,
            // now with this player's files and lengths in it.
            // P4d: a player's new folders join the show only while it is
            // the unsaved all-works show; otherwise they wait in the pool.
            show = SharedShow.merge(show, with: inv, conductor: Self.thisMac, addingNewWorks: autoShow)
            markAutoBaseline()               // a player's works, not a person's edit
            scheduleShare()                  // lengths may change even if the show doesn't
        case .report(let machine, let blocking):
            players[id, default: PlayerLink()].machine = machine
            players[id]?.blocking = blocking
        case .setScreen(let machine, let work, let index, let panel):
            // [claude] A person on that player set one of its own screens
            // (Mat, 2026-10-22). Recorded in the show (autosave keeps it)
            // and shared back, so every Mac has one version of the show.
            NSLog("link: %@ set %@ screen %d to %@", machine, work, index + 1, panel.file ?? "black")
            show = SharedShow.setScreen(show, machine: machine, work: work, index: index, panel: panel)
        case .show:
            break                            // only a conductor sends these
        }
    }

    /// Shares the show on the next turn of the run loop. COALESCING: an edit
    /// can change the show many times in one go (a scan touches every work),
    /// and the players only need the result.
    private func scheduleShare() {
        guard mode == .conductor, !shareScheduled else { return }
        shareScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.shareScheduled = false
                self?.shareShow(to: nil)
            }
        }
    }

    private func shareShow(to id: ObjectIdentifier?) {
        guard let linkServer else { return }
        linkServer.send(.show(show, lengths: show.works.indices.map(length(of:))), to: id)
    }

    // Player side.

    private func linkConnected(name: String, ipv4: String?) {
        linkUp = true
        severalConductors = []
        // [claude] P4b: a conductor found by Bonjour also gets this Mac's
        // clock pointed at it (the clock needs an address; discovery gives
        // the link one, so the clock follows the link). A typed address
        // already started the clock in restartClock.
        if conductorAddress.trimmingCharacters(in: .whitespaces).isEmpty, let ipv4, foundConductor?.ipv4 != ipv4 {
            client?.stop()
            client = nil
            follower = StateFollower()
            do { try startClockClient(ipv4) } catch { clockStatus = "Clock: \(error)" }
            foundConductor = (name, ipv4)
            NSLog("clock: following %@ at %@ (found on the network)", name, ipv4)
        }
        sentInventory = nil
        sentReport = nil
        linkClient?.send(.hello(machine: Self.thisMac, build: Self.build))
        refreshInventory()
    }

    private func playerReceived(_ m: LinkMessage) {
        guard mode == .player, case .show(let s, let lengths) = m else { return }
        guard s != show || lengths != sharedLengths else { return }
        // The conductor's playlist replaces this Mac's: one show, everywhere.
        // A player's own show file isn't used in Player mode.
        replacingShow = true
        show = s
        replacingShow = false
        sharedLengths = lengths
        selectedWork = min(selectedWork, max(s.works.count - 1, 0))
        NSLog("link: playlist from the conductor: %d work(s)", s.works.count)
        loadAllInfo()
        sendReport()
    }

    /// Player, every 5 s and on connecting: list the media folder; measure
    /// any file that is new or changed; once everything is measured, send
    /// the inventory if it differs from the last one sent. This is the
    /// "still has what it reported" check (§ Media on several Macs): a file
    /// renamed, replaced or removed shows up within 5 s.
    private func refreshInventory() {
        guard mode == .player, linkUp, !mediaFolder.isEmpty else { return }
        let fm = FileManager.default
        var folders: [String: [InventoryFile]] = [:]
        var complete = true
        for folder in (try? fm.contentsOfDirectory(atPath: mediaFolder)) ?? [] where !folder.hasPrefix(".") {
            let dir = (mediaFolder as NSString).appendingPathComponent(folder)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            var files: [InventoryFile] = []
            for name in FolderScan.videos(names) {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let a = try? fm.attributesOfItem(atPath: path) else { continue }
                let stamp = ((a[.size] as? Int64) ?? 0, (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
                if let old = stamps[path], old != stamp { media[path] = nil; unreadable.remove(path) }
                stamps[path] = stamp
                if unreadable.contains(path) { continue }         // not a playable video: not offered
                guard let info = media[path] else { loadInfo(path); complete = false; continue }
                files.append(InventoryFile(name: name, size: stamp.0, modified: stamp.1, duration: info.duration,
                                           fps: info.fps, hasAudio: info.hasAudio))
            }
            if !files.isEmpty { folders[folder] = files }
        }
        // [claude] Files linked to this Mac's screens from outside the library
        // (a person chose them here, Mat 2026-10-22): reported under their
        // folder's full path, so the conductor's lengths and file check
        // include them. They are not works (ShowFolder.pool skips them).
        if let me = machineName {
            for work in show.works {
                for f in (work.screens[me] ?? []).compactMap(\.file) where f.hasPrefix("/") {
                    guard let a = try? fm.attributesOfItem(atPath: f) else { continue }
                    guard let info = media[f] else { loadInfo(f); complete = false; continue }
                    let dir = (f as NSString).deletingLastPathComponent, name = (f as NSString).lastPathComponent
                    guard !(folders[dir]?.contains { $0.name == name } ?? false) else { continue }
                    folders[dir, default: []].append(InventoryFile(
                        name: name, size: (a[.size] as? Int64) ?? 0,
                        modified: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                        duration: info.duration, fps: info.fps, hasAudio: info.hasAudio))
                }
            }
        }
        guard complete else { return }                           // try again when the measuring is done
        let inv = Inventory(machine: Self.thisMac, displays: displays.count, folders: folders)
        if inv != sentInventory {
            sentInventory = inv
            linkClient?.send(.inventory(inv))
            NSLog("link: sent inventory: %d folder(s)", folders.count)
        }
    }

    /// Player: tell the conductor what stops this Mac playing, when it changes.
    private func sendReport() {
        guard mode == .player, linkUp, sharedLengths != nil else { return }
        let blocking = fileProblems()
        guard blocking != sentReport else { return }
        sentReport = blocking
        linkClient?.send(.report(machine: Self.thisMac, blocking: blocking))
    }

    /// One line per player for setup, e.g. "Mac B: 3 displays, ready".
    var playerLines: [String] {
        players.values.map { p in
            let name = p.machine ?? "a player"
            if let b = p.build, b != Self.build { return "\(name): runs build \(b), this Mac runs \(Self.build)" }
            guard let inv = p.inventory else { return "\(name): listing its files…" }
            let state = p.blocking.map { $0.isEmpty ? "ready" : "\($0.count) problem(s)" } ?? "checking its files…"
            return "\(name): \(inv.displays) display\(inv.displays == 1 ? "" : "s"), \(state)"
        }.sorted()
    }

    private func updateClockStatus() {
        statusTicks += 1
        let line = playback?.statusLine ?? ""
        if line != remoteStatus { remoteStatus = line }          // [claude] the remote controls' line
        server?.broadcast()          // the once-a-second repeat of the show state
        if statusTicks % 5 == 0 { refreshInventory(); sendReport(); rescan() }    // [claude] player: inventory; others: the library
        if let server {
            let players = server.players()
            clockStatus = "Conductor: answering clock requests on \(server.addresses.joined(separator: ", "))"
                + (players.isEmpty ? ". No players yet." : ". Players: \(players.joined(separator: ", ")).")
        } else if let client {
            clockStatus = Self.describe(client.status)
                + " · conductor " + (follower.current.map { "\($0.phase)" } ?? "not heard from yet")
        } else if mode == .player {
            // [claude] P4b: no address = looking for one.
            clockStatus = severalConductors.isEmpty
                ? "Player: looking for a conductor on this network… (or type its address and press Return)"
                : "Player: several conductors found (\(severalConductors.joined(separator: ", "))). Type the address of the one to follow."
        } else if clockStatus.hasPrefix("Clock:") == false {
            clockStatus = ""
        }
        if statusTicks % 10 == 0, !clockStatus.isEmpty { NSLog("clock: %@", clockStatus) }
    }

    /// e.g. "Player of 10.0.0.5: 20 replies/s · steady to 0.28 ms · drift −12.0 ppm · offset 765898979.83 ms".
    /// The thresholds are the targets: no reply in 5 s is T10 failing, a
    /// spread over 5 ms is T11 failing.
    private static func describe(_ s: ClockClient.Status) -> String {
        let head = "Player of \(s.conductor)"
        guard let since = s.secondsSinceReply else {
            return s.secondsRunning > 5
                ? "\(head): no replies. Check the address, that the conductor is running, and that this network lets Macs reach each other."
                : "\(head): asking…"
        }
        if since > 5 { return String(format: "%@: no replies for %.0f s; running on the last estimate.", head, since) }
        var parts = [String(format: "%.0f replies/s", s.repliesPerSecond)]
        if let st = s.steadiness {
            parts.append(String(format: "steady to %.2f ms%@", st * 1000, st > 0.005 ? " (over 5 ms)" : ""))
        } else {
            parts.append("measuring steadiness…")
        }
        if let d = s.drift { parts.append(String(format: "drift %.1f ppm", d * 1e6)) }
        // In ms, as the probe prints it, so the two can be compared directly.
        if let o = s.offset { parts.append(String(format: "offset %.2f ms", o * 1000)) }
        return "\(head): " + parts.joined(separator: " · ")
    }

    /// Called once the setup window is on screen; starts "Play on launch".
    ///
    /// [claude] This used to happen in init, which runs before SwiftUI has made
    /// the setup window. play() hides the setup windows it can find, and at that
    /// moment there were none, so the setup window appeared afterwards, became
    /// the key window behind the playback windows, and took Space and Esc. The
    /// fix is about ORDER OF INITIALISATION: act on the window only once it
    /// exists. The flag makes it a ONE-SHOT, because SwiftUI may call onAppear
    /// again when the window is shown after playback, and that must not restart
    /// the show.
    func launched() {
        guard !hasLaunched else { return }
        hasLaunched = true
        startupStatus = "Looking for the library…"
        // A moment's delay so the window (and that line) is drawn before the
        // search, which can block while a drive spins up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.startUp() }
        }
    }

    // MARK: Launch, with an indicator (Mat, 2026-10-22) [claude]

    /// What the launch is doing, for the banner; nil when done or skipped.
    @Published private(set) var startupStatus: String?
    /// Skip pressed: the banner goes, and a show set to start presenting at
    /// launch doesn't (this time). Measuring carries on: lengths need it.
    private var startupSkipped = false

    func skipStartup() {
        startupSkipped = true
        startupStatus = nil
        NSLog("startup: skipped")
    }

    private func startUp() {
        let t0 = Date()
        // Find the folder, show and role (P4b), then start the clock once.
        // The role set here isn't "chosen by hand": clockReady is still false.
        findEverything()
        clockReady = true
        restartClock()
        NSLog("startup: library in %.2f s (%@)", Date().timeIntervalSince(t0), mediaFolder.isEmpty ? "none" : mediaFolder)
        Task {
            let t1 = Date()
            let total = infoLoads.count + media.count
            while !infoLoads.isEmpty {
                if !startupSkipped { startupStatus = "Measuring videos: \(total - infoLoads.count) of \(total)…" }
                try? await Task.sleep(for: .milliseconds(200))
            }
            NSLog("startup: %d video(s) measured in %.2f s", total, Date().timeIntervalSince(t1))
            let wantsPresent = show.playOnLaunch, wantsPreview = CommandLine.arguments.contains("--preview")
            if !startupSkipped, wantsPresent || wantsPreview {
                startupStatus = wantsPreview ? "Opening the preview…" : "Starting the show…"
            } else {
                startupStatus = nil
            }
            // [claude] P4e: `--preview` on the command line opens the preview
            // at launch, so it can be checked without a person clicking.
            if wantsPreview { startupStatus = nil; preview(); return }
            guard wantsPresent, !startupSkipped else { startupStatus = nil; return }
            startupStatus = nil
            play()
        }
    }

    // MARK: Displays

    private func refreshDisplays() {
        displays = DisplayOrder.sorted(NSScreen.screens.compactMap(Self.info(for:)))
        // [claude] The show records how many displays this Mac has (§ v4 ›
        // Model). Panels are padded per work when read (`panels(of:)`), and
        // extra panels from a bigger array are kept, so saving on this
        // machine doesn't lose them. New displays take unused files.
        //
        // [claude] The count in the show is the DESIGN (Mat, 2026-10-22):
        // it grows when more displays are connected, never shrinks when
        // fewer are (a laptop standing in for the gallery Mac). Only
        // setDisplays (a person) makes it smaller.
        if let mi = machineIndex, !conductsOnly, show.machines[mi].displays < displays.count {
            show.machines[mi].displays = displays.count
        }
        fillNewDisplays()
    }

    /// This Mac's displays as the show is designed: what setup lists, what
    /// a scan assigns and what the preview shows. A real show plays on as
    /// many of them as are connected.
    var designDisplays: Int {
        // [claude] Compose ahead, step 3: a Mac that only conducts has none.
        if conductsOnly { return 0 }
        return max(machineIndex.map { show.machines[$0].displays } ?? 0, displays.count)
    }

    /// This Mac takes part with no screens: it conducts (from the setup
    /// window's remote controls) while the other Macs present.
    var conductsOnly: Bool { machineIndex.map { show.machines[$0].noScreens == true } ?? false }

    /// [claude] Sizes this Mac's part by what its works need (the highest
    /// "_N", or the most files in a work), when a show is first made from
    /// the folder (Mat, 2026-10-22: a 1-display laptop left _2 and _3 unused).
    /// Never shrinks.
    private func sizeThisMacByWorks() {
        guard let mi = machineIndex, let l = Self.listing(mediaFolder) else { return }
        let needed = FolderScan.displaysNeeded(l.subfolders, firstScreen: firstScreen)
        show.machines[mi].displays = min(max(show.machines[mi].displays, displays.count, needed), 16)
    }

    /// "Displays in this show" for Mac `m`, set by hand (1–16). Shrinking
    /// keeps the panels beyond the count, unused, so growing again restores
    /// them.
    func setDisplays(_ m: String, _ n: Int) {
        guard let i = show.machines.firstIndex(where: { $0.name == m }) else { return }
        // [claude] 0 = this Mac only conducts (step 3): its design count is
        // kept, so going back up restores its screens.
        if n <= 0, m == machineName, mode == .conductor {
            show.machines[i].noScreens = true
            return
        }
        show.machines[i].noScreens = nil
        show.machines[i].displays = min(max(n, 1), 16)
        if m == machineName { fillNewDisplays() }
    }

    private func screensChanged() {
        // A display vanishing mid-show would leave a panel playing nowhere and the
        // others out of their arrangement, so stop and let a person look.
        //
        // [claude] But only if the displays REALLY changed. macOS posts this
        // notification for things that aren't display changes at all, and
        // Playback causes one itself: hiding the Dock and menu bar for the show
        // posts it, so the show used to stop itself a moment after starting
        // (confirmed by logging the display list before and after: identical).
        // Comparing the canonical sorted list (id, name, position, pixel size)
        // turns a noisy EVENT into a real STATE CHANGE before acting on it.
        let now = DisplayOrder.sorted(NSScreen.screens.compactMap(Self.info(for:)))
        guard now != displays else { return }
        if isPlaying {
            NSLog("Displays changed during playback (%d -> %d); stopping", displays.count, now.count)
            stop()
            lastError = "Displays changed during playback, so playback stopped."
        }
        refreshDisplays()
    }

    static func info(for screen: NSScreen) -> DisplayInfo? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(n.uint32Value)
        // The display MODE has the real pixel count. NSScreen.frame is in points,
        // which on a HiDPI ("looks like 1920 × 1080") 4K screen is half the pixels.
        let mode = CGDisplayCopyDisplayMode(id)
        let pixels = CGSize(width: mode?.pixelWidth ?? Int(screen.frame.width),
                            height: mode?.pixelHeight ?? Int(screen.frame.height))
        return DisplayInfo(id: id, name: screen.localizedName, frame: screen.frame, pixelSize: pixels)
    }

    // MARK: Panels

    /// [claude] A file chosen by hand is stored relative to the media folder
    /// when it is inside it (so the show moves with the folder), else as a
    /// full path.
    func choose(panel i: Int) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie]
        if !mediaFolder.isEmpty { p.directoryURL = URL(fileURLWithPath: mediaFolder) }
        guard p.runModal() == .OK, let url = p.url, i < panels.count else { return }
        let prefix = mediaFolder.hasSuffix("/") ? mediaFolder : mediaFolder + "/"
        var panel = panels[i]
        panel.file = !mediaFolder.isEmpty && url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
        setPanel(i, panel)
        loadInfo(url.path)
    }

    func clear(panel i: Int) {
        guard i < panels.count else { return }
        var panel = panels[i]
        panel.file = nil
        setPanel(i, panel)
    }

    private func loadInfo(_ path: String) {
        guard media[path] == nil, infoLoads[path] == nil else { return }
        infoLoads[path] = Task {
            do {
                media[path] = try await Self.readInfo(URL(fileURLWithPath: path))
                unreadable.remove(path)
            } catch {
                unreadable.insert(path)
            }
            infoLoads[path] = nil
            // [claude] P3b: a measured file can change a work's length (the
            // conductor re-shares) or complete a player's inventory.
            switch mode {
            case .conductor: scheduleShare()
            case .player: if infoLoads.isEmpty { refreshInventory(); sendReport() }
            case .standalone: break
            }
        }
    }

    /// [claude] File reads in progress, kept so Play on launch can wait for
    /// them: in v4 a work's length (its longest file) times the playlist, so
    /// a show can't start until its files are measured. Without the wait,
    /// Play on launch was refused with "still reading" (found in the P2 run,
    /// 2026-10-21) and the show never started.
    private var infoLoads: [String: Task<Void, Never>] = [:]

    private func infoLoaded() async {
        while let pending = infoLoads.values.first { await pending.value }
    }

    static func readInfo(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let v = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (natural, transform, fps) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        // Phone video is often stored sideways with a rotation flag; apply it so
        // an upright clip reports as upright (1080 × 1920, not 1920 × 1080).
        let shown = natural.applying(transform)
        let audio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        return MediaInfo(size: CGSize(width: abs(shown.width), height: abs(shown.height)),
                         duration: duration, fps: Double(fps), hasAudio: audio)
    }

    func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Problems that block playback (missing or unreadable files) or deserve a
    /// warning (lengths that differ, so panels will drift in phase).
    ///
    /// [claude] v4: checked across every work in the playlist, each problem
    /// named by its work, since the one on screen in setup may not be the
    /// one with the missing file.
    var problems: (blocking: [String], warnings: [String]) {
        var blocking: [String] = [], warnings: [String] = []
        // [claude] P3b: a player plays the conductor's playlist, not its own.
        if mode == .player, mediaFolder.isEmpty {
            return (["Choose this Mac's media folder: the conductor builds the playlist from what each Mac has."], [])
        }
        if mode == .player, sharedLengths == nil {
            return ([linkUp ? "Waiting for the conductor's playlist…" : "Not connected to the conductor yet."], [])
        }
        if machineIndex == nil {
            let names = show.machines.map(\.name).joined(separator: ", ")
            return (["This show has parts for \(names), but not for this Mac (\(Self.thisMac))."], [])
        }
        if show.works.isEmpty {
            // [claude] P4d: say which of the two empties it is.
            return ([libraryWorks.isEmpty
                     ? "The library has no works yet: put each work in a folder inside \(ShowFolder.worksName), then press Scan."
                     : "This show has no works: use Add from library."], [])
        }
        // [claude] Copying gigabytes while playing would compete with the
        // players for the disk; a collect is short and run by a person.
        if collecting != nil { blocking.append("Wait for the collect to finish.") }
        blocking += fileProblems()
        for work in show.works {
            if let extra = leftOver[work.name] {
                warnings.append("\(work.name): \(extra.count) file(s) not used on this Mac (more files than displays, or numbered for another screen): \(extra.joined(separator: ", ")).")
            }
        }
        // [claude] Interface step 1: one note for the whole show (it was one
        // per work), and only when some screen beyond the connected ones
        // actually has a file.
        if designDisplays > displays.count,
           show.works.indices.contains(where: { panels(of: $0).dropFirst(displays.count).contains { $0.file != nil } }) {
            warnings.append("This Mac has \(displays.count) of the \(designDisplays) displays this show is designed for: screens beyond \(displays.count) play in Preview, not when presenting here.")
        }
        if blocking.isEmpty, !show.works.indices.contains(where: { length(of: $0) > 0 }) {
            blocking.append("No work has a file for this Mac's displays.")
        }
        // [claude] P3b, the conductor's file check (§ Media on several
        // Macs): every connected player must have listed its files and
        // found nothing missing, on the same build. A Mac in the show that
        // isn't connected only warns: its screens stay black, and a show may
        // reasonably run with a Mac switched off.
        if mode == .conductor {
            for p in players.values {
                let name = p.machine ?? "A player"
                if let b = p.build, b != Self.build {
                    blocking.append("\(name) runs tableauX \(b); this Mac runs \(Self.build). Use the same build on every Mac.")
                } else if p.inventory == nil || p.blocking == nil {
                    blocking.append("Waiting for \(name) to check its files…")
                } else {
                    blocking += p.blocking!.map { "\(name): \($0)" }
                }
            }
            let connected = Set(players.values.compactMap(\.machine))
            for m in show.machines where m.name != machineName && !connected.contains(m.name) {
                warnings.append("\(m.name) isn't connected: its screens will stay black.")
            }
        }
        return (blocking, warnings)
    }

    /// This Mac's own files that stop it playing: missing, unreadable, or
    /// not measured yet. A player sends exactly these to the conductor.
    private func fileProblems() -> [String] {
        var out: [String] = []
        for (w, work) in show.works.enumerated() {
            for (i, p) in panels(of: w).prefix(displays.count).enumerated() {
                guard let file = p.file else { continue }
                let f = resolve(file)
                if !fileExists(f) { out.append("\(work.name), display \(i + 1): file not found (\(f)).") }
                else if unreadable.contains(f) { out.append("\(work.name), display \(i + 1): can't read this file as video.") }
                else if media[f] == nil { out.append("\(work.name), display \(i + 1): still reading the file…") }
            }
        }
        return out
    }

    // MARK: Show files

    /// Show files are `.tableaux`. Open also accepts `.msshow`, the extension
    /// from before the app was renamed: the contents are the same format (the
    /// version number inside is what ShowFile checks), so only the name moved.
    static let showExtension = "tableaux"
    static let legacyShowExtension = "msshow"

    func openDialog() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [Self.showExtension, Self.legacyShowExtension]
            .compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK, let url = p.url { open(url) }
    }

    func open(_ url: URL) {
        // [claude] Autosave: the current show's last edit is written before
        // it is replaced; an edited all-works show asks first.
        flushAutosave()
        guard confirmLeavingAutoShow() else { return }
        replacingShow = true
        defer { replacingShow = false }
        do {
            let opened = try ShowFile.decode(Data(contentsOf: url))
            // [claude] P4d: switching shows mid-performance would leave the
            // old show's players on screen; stop first.
            if isPlaying { stop() }
            show = opened
            showPath = url
            autoShow = false
            selectedWork = 0
            leftOver = [:]
            claimOwnPart()                   // [claude] compose ahead, step 2
            UserDefaults.standard.set(url.path, forKey: lastShowKey)
            refreshDisplays()
            // [claude] P4d: on a conductor, the players already connected
            // fold into the newly opened show (their machines and screens,
            // never new works); the show's didSet then sends it, so every
            // player follows the switch.
            if mode == .conductor {
                for inv in reported.values {
                    show = SharedShow.merge(show, with: inv, conductor: Self.thisMac, addingNewWorks: false)
                }
            }
            refreshLibrary()
            // Only this Mac's files: the other machines' paths are on their disks.
            loadAllInfo()
        } catch {
            lastError = "Couldn't open \(url.lastPathComponent): \(error)"
        }
    }

    func saveDialog() {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: Self.showExtension) ?? .json]
        // [claude] P4d: shows are kept in the library's shows folder.
        if !showsFolder.isEmpty {
            try? FileManager.default.createDirectory(atPath: showsFolder, withIntermediateDirectories: true)
            p.directoryURL = URL(fileURLWithPath: showsFolder)
        }
        // Saving an old .msshow offers the same name with the new extension.
        let base = showPath?.deletingPathExtension().lastPathComponent ?? (autoShow ? "All works" : "Untitled")
        p.nameFieldStringValue = "\(base).\(Self.showExtension)"
        guard p.runModal() == .OK, let url = p.url else { return }
        save(to: url)
    }

    private func save(to url: URL) {
        do {
            try ShowFile.encode(show).write(to: url)
            showPath = url
            autoShow = false            // saved = curated (§ Library)
            autoShowEdited = false
            autosaveTimer?.invalidate()
            autosaveTimer = nil
            UserDefaults.standard.set(url.path, forKey: lastShowKey)
            refreshLibrary()
        } catch {
            lastError = "Couldn't save: \(error)"
        }
    }

    // MARK: Playback

    func play() {
        // [claude] On a player, Play means "join the conductor's show", never
        // "start on my own clock": that played out of sync (Mat, 0.1.2).
        if mode == .player {
            dismissedVersion = nil
            if follower.current?.phase == .playing { reconcile() }
            else { lastError = "This Mac is a Player: it starts when the conductor presses Play." }
            return
        }
        startPlayback(following: nil)
    }

    /// Starts this Mac's part. `following` nil = this Mac leads (standalone or
    /// conductor); otherwise it joins the conductor's state.
    private func startPlayback(following s: ShowState?) {
        // [claude] Say why a Play does nothing. Before this, a refused Play was
        // a silent return, which is exactly what "nothing happened" looks like.
        NSLog("Play pressed: %d display(s), %d work(s)", displays.count, show.works.count)
        if isPlaying { NSLog("Play refused: already playing"); return }
        let blocking = problems.blocking
        if !blocking.isEmpty {
            // A player retries every second; say so once per conductor state.
            if s == nil || s?.version != refusedVersion {
                NSLog("Play refused: %@", blocking.joined(separator: " | "))
                if s != nil { lastError = "Can't follow the conductor: " + blocking.joined(separator: " ") }
            }
            refusedVersion = s?.version
            return
        }
        var clock = ShowClock.local
        if s != nil {
            // No estimate of the conductor's clock yet: wait for the next state.
            guard let client, client.hostTime(conductor: 0) != nil else { return }
            clock = .following(client)
        }
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { s in
            Self.info(for: s).map { ($0.id, s) }
        })
        // [claude] Step 3: a Mac that only conducts presents on no screens
        // of its own: no full-screen windows, the setup window stays (with
        // the remote controls), the players present.
        let ordered = conductsOnly ? [] : displays.compactMap { screens[$0.id] }
        // [claude] Each work's part on this Mac, files resolved to full paths
        // and measured: what Playback needs to lay out and time every work.
        let parts = show.works.indices.map { w -> WorkPart in
            let ps = panels(of: w).prefix(ordered.count).map { p -> PanelConfig in
                var p = p
                p.file = p.file.map(resolve)
                return p
            }
            let durations = Dictionary(ps.compactMap { p in p.file.flatMap { f in media[f].map { (f, $0.duration) } } },
                                       uniquingKeysWith: { a, _ in a })
            let work = show.works[w]
            return WorkPart(name: work.name, panels: Array(ps), durations: durations, length: length(of: w),
                            repeat: work.repeat, shorter: work.shorter)
        }
        lastError = nil
        // The setup window is hidden only once the panel windows are up, never
        // before: hiding the last visible window quits the app (see Playback.init).
        // A leader reports each state change; on a conductor that goes to the
        // players, standalone it goes nowhere (server is nil).
        let report: ((ShowState) -> Void)? = s != nil ? nil : { [weak self] state in self?.server?.publish(state) }
        let pb = Playback(screens: ordered, works: parts, playlist: show.playlist, sync: show.sync, clock: clock,
                          allowSkip: true, onStateChange: report,     // [claude] P3a: players follow → / ← via the state's work index
                          onWindowsUp: { [weak self] in
                              // With no screens of its own the setup window IS the
                              // control surface; hiding it would also quit the app.
                              guard !ordered.isEmpty else { return }
                              self?.setupWindows.forEach { $0.orderOut(nil) }
                          },
                          onEnd: { [weak self] in self?.playbackEnded() })
        playback = pb
        isPlaying = true
        pb.start(following: s.map { ($0.index, $0.start) })
    }

    // MARK: Kits (compose ahead, step 4) [claude]

    /// Show menu › "Make kits for each Mac…": asks where, and which Mac
    /// conducts, then writes one folder per Mac: the app, a Works/ with that
    /// Mac's files at their library paths, and for a gallery-Mac conductor
    /// Shows/ with the show. Copy each folder to its Mac and open the app:
    /// the folder sets the role and the Mac claims its part by its files.
    func makeKits() {
        guard collecting == nil, !show.works.isEmpty else { return }
        // Which Mac conducts: this one (keeps the show) or one in the tableau.
        let a = NSAlert()
        a.messageText = "Make a kit for each Mac"
        a.informativeText = "Which Mac conducts at the gallery? Its kit also gets the show. If this Mac conducts, it keeps the show and the kits are for the others."
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        let others = show.machines.filter { $0.name != machineName }
        menu.addItem(withTitle: "This Mac (\(machineName.map(displayName(of:)) ?? Self.thisMac))")
        others.forEach { menu.addItem(withTitle: $0.displayName) }
        a.accessoryView = menu
        a.addButton(withTitle: "Choose Where…")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let conductor: String? = menu.indexOfSelectedItem == 0 ? nil : others[menu.indexOfSelectedItem - 1].name
        guard let dir = chooseCollectFolder() else { return }

        let kits = Kits.plan(show: show, conductor: conductor, resolve: resolve).filter { $0.machine != machineName || conductor == machineName }
        let showName = showPath?.deletingPathExtension().lastPathComponent ?? "Show"
        let showData = try? ShowFile.encode(show)
        let ext = Self.showExtension
        let app = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
        let fm = FileManager.default
        let missing = kits.flatMap { $0.copies.map(\.source) }.filter { !fileExists($0) }
        let linked = Set(kits.flatMap(\.linked))
        let total = kits.reduce(0) { $0 + $1.copies.count }
        collecting = "Making kits: 0 of \(total) files…"
        NSLog("kits: %d kit(s), %d file(s) into %@", kits.count, total, dir.path)
        Task.detached {
            var done = 0, failure: String?
            do {
                for kit in kits {
                    let root = dir.appendingPathComponent(Collect.uniqueName("\(showName) – \(Collect.folderName(kit.label))", taken: []))
                    let works = root.appendingPathComponent(ShowFolder.worksName)
                    try fm.createDirectory(at: works, withIntermediateDirectories: true)
                    if let app { try? fm.copyItem(at: app, to: root.appendingPathComponent(app.lastPathComponent)) }
                    if kit.withShow, let showData {
                        let shows = root.appendingPathComponent(ShowFolder.showsName)
                        try fm.createDirectory(at: shows, withIntermediateDirectories: true)
                        try showData.write(to: shows.appendingPathComponent("\(showName).\(ext)"))
                    }
                    for c in kit.copies where fm.fileExists(atPath: c.source) {
                        let dest = works.appendingPathComponent(c.dest)
                        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if !fm.fileExists(atPath: dest.path) { try fm.copyItem(atPath: c.source, toPath: dest.path) }
                        done += 1
                        let n = done
                        await MainActor.run { self.collecting = "Making kits: \(n) of \(total) files…" }
                    }
                }
            } catch {
                failure = "Making kits stopped: \(error.localizedDescription)"
            }
            await MainActor.run { [failure, done] in
                self.collecting = nil
                if let failure { self.lastError = failure; return }
                var note = "Made \(kits.count) kit(s) with \(done) file(s)"
                if !missing.isEmpty { note += "; \(missing.count) file(s) not on this Mac" }
                if !linked.isEmpty { note += "; \(linked.count) linked file(s) left out (Collect the show first)" }
                self.libraryNote = note + "."
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
        }
    }

    // MARK: Remote controls (compose ahead, step 3) [claude]

    /// What's playing, for the remote control strip; refreshed every second.
    @Published private(set) var remoteStatus = ""

    /// The conductor's controls when it has no screens to take keys:
    /// the same actions as Space, → / ← and Esc on a panel window.
    func remotePause() { playback?.togglePause() }
    func remoteSkip(forward: Bool) { playback?.skip(forward: forward) }

    func stop() { playback?.stop() }

    // MARK: Preview (v4 P4e) [claude]

    /// True while a preview (not a show) is playing.
    @Published private(set) var previewing = false

    /// Every screen of the tableau, the file it would play resolved against
    /// THIS Mac's library, or nil if that file isn't here.
    private func previewPanels(_ work: Work, onlyMachine: String? = nil) -> [PanelConfig] {
        PreviewLayout.rows(show, work: work).flatMap { $0 }.filter { onlyMachine == nil || $0.machine == onlyMachine }.map { t in
            var p = t.panel
            p.file = p.file.map(resolve).flatMap { fileExists($0) && !unreadable.contains($0) ? $0 : nil }
            return p
        }
    }

    /// Plays the show in one window, the whole tableau as tiles, a row per
    /// Mac (Mat, 2026-10-22: "test my shows on a single screen"). The same
    /// engine and timeline as a real show, on this Mac's own clock; nothing
    /// is sent to players.
    func preview() {
        guard !isPlaying, !show.works.isEmpty else { return }
        // The other Macs' files are only measured when previewing.
        for w in show.works { previewPanels(w).compactMap(\.file).forEach(loadInfo) }
        Task {
            await infoLoaded()
            startPreview(following: nil)
        }
    }

    /// [claude] Networked preview (Mat, 2026-10-22): a player following the
    /// conductor's preview opens its own preview, of ITS screens only.
    private var previewStarting = false

    private func previewFollowing(_ s: ShowState) {
        guard !previewStarting else { return }          // states arrive every second; once is enough
        previewStarting = true
        for w in show.works { previewPanels(w).compactMap(\.file).forEach(loadInfo) }
        Task {
            await infoLoaded()
            previewStarting = false
            // The conductor may have moved on while this Mac measured.
            guard let now = follower.current, now.preview, now.phase != .stopped else { return }
            startPreview(following: now)
        }
    }

    /// `following` nil: this Mac leads (standalone, or the conductor, whose
    /// preview is published so players preview with it). Otherwise a player
    /// joining the conductor's preview with its own screens.
    private func startPreview(following s: ShowState?) {
        guard !isPlaying else { return }
        let me = machineName
        let ownOnly = s != nil
        var clock = ShowClock.local
        if s != nil {
            guard let client, client.hostTime(conductor: 0) != nil else { return }      // no clock yet: next state
            clock = .following(client)
        }
        let parts = show.works.enumerated().map { w, work -> WorkPart in
            let ps = previewPanels(work, onlyMachine: ownOnly ? me : nil)
            let durations = Dictionary(ps.compactMap { p in p.file.flatMap { f in media[f].map { (f, $0.duration) } } },
                                       uniquingKeysWith: { a, _ in a })
            // Across Macs every preview must time works alike: the shared
            // lengths (a player's are the conductor's). On its own, a Mac
            // may also use the longest file it happens to have.
            let len = mode == .standalone ? max(length(of: w), durations.values.max() ?? 0) : length(of: w)
            return WorkPart(name: work.name, panels: ps, durations: durations, length: len,
                            repeat: work.repeat, shorter: work.shorter)
        }
        guard s != nil || parts.contains(where: { $0.length > 0 }) else {
            lastError = "Nothing to preview: none of this show's files are on this Mac."
            return
        }
        let labels = PreviewLayout.rows(show, work: show.works[0])
            .filter { !ownOnly || $0.first?.machine == me }
            .map { row in row.map { "\(displayName(of: $0.machine)) · display \($0.display) · screen \($0.screen)" } }
        lastError = nil
        // A conductor's preview is published (flagged preview) so players
        // preview with it; standalone leads and tells nobody; a player follows.
        let report: ((ShowState) -> Void)? = s != nil ? nil
            : mode == .conductor ? { [weak self] state in self?.server?.publish(state) } : { _ in }
        let pb = Playback(screens: [], works: parts, playlist: show.playlist, sync: show.sync, clock: clock,
                          allowSkip: true, onStateChange: report,
                          onWindowsUp: {}, onEnd: { [weak self] in self?.playbackEnded() },
                          preview: labels)
        playback = pb
        isPlaying = true
        previewing = true
        NSLog("preview: %d work(s), %d screen(s)%@", parts.count, labels.joined().count, s != nil ? ", following the conductor" : "")
        pb.start(following: s.map { ($0.index, $0.start) })
    }

    static let setupTitle = "tableauX"
    private var setupWindows: [NSWindow] {
        NSApp.windows.filter { !($0 is PanelWindow) && $0.title == Self.setupTitle }
    }

    private func playbackEnded() {
        if let failure = playback?.failure { lastError = failure; NSLog("%@", failure) }
        playback = nil
        isPlaying = false
        let wasPreview = previewing
        previewing = false
        setupWindows.forEach { $0.makeKeyAndOrderFront(nil) }
        // [claude] Standalone, a preview told nobody it started. A conductor's
        // preview did (networked preview), so its end is published below.
        if wasPreview, mode == .standalone { return }
        if switchingKind { return }         // a player changing kind, not a person's Esc
        // [claude] The conductor's Esc ends the show everywhere.
        if mode == .conductor { server?.publish(ShowState(version: hostNanos(), phase: .stopped)) }
        // A player stopped by a person (not by the conductor) stays out of this state.
        if mode == .player, let current = follower.current, current.phase != .stopped {
            dismissedVersion = current.version
        }
    }
}
