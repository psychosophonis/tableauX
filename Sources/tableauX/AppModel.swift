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
        didSet { if mode == .conductor { scheduleShare() } }
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
        while ps.count < displays.count { ps.append(PanelConfig()) }
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
    }

    // MARK: Another Mac's screens, set from the conductor (v4 P4a) [claude]

    /// Whose screens setup is showing: nil = this Mac's. Conductor only:
    /// § Getting works in › Manual, "a player's screen is chosen from the
    /// files that player reported, without visiting it".
    @Published var editingMachine: String?

    /// The other Macs in the show, in screen-numbering order.
    var otherMachines: [Machine] { show.machines.filter { $0.name != machineName } }

    /// Machine `m`'s panels for the selected work, one per display it has
    /// (as it last reported, or as saved).
    func panels(on m: String) -> [PanelConfig] {
        guard show.works.indices.contains(selectedWork) else { return [] }
        let count = show.machines.first(where: { $0.name == m })?.displays ?? 0
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
        panels(of: w).prefix(displays.count).compactMap { $0.file.flatMap { media[resolve($0)]?.duration } }.max() ?? 0
    }

    /// One play of work `w` (§ v4 › Playing): its longest file on ANY Mac.
    /// [claude] P3b: every Mac must time the playlist by the same numbers,
    /// so a conductor takes the longest across its own files and every
    /// player's inventory, and a player uses exactly what the conductor sent.
    func length(of w: Int) -> Double {
        switch mode {
        case .standalone: return ownLength(of: w)
        case .conductor:
            guard show.works.indices.contains(w) else { return 0 }
            return max(ownLength(of: w), PlaylistMerge.length(of: show.works[w], in: Array(reported.values)))
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
        mediaFolder = url.path
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
        guard !mediaFolder.isEmpty, let l = Self.listing(mediaFolder) else { return [] }
        return ShowFolder.shows(in: l.files).map { name in
            let p = (mediaFolder as NSString).appendingPathComponent(name)
            let d = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? nil
            return (p, d?.timeIntervalSince1970 ?? 0)
        }
    }

    /// Launch: find the media folder, open the show, pick the role
    /// (§ v4 › Zero setup). Runs once, from init, before the clock starts.
    private func findEverything() {
        let chosen = UserDefaults.standard.string(forKey: mediaKey)
        let app = Self.appFolder
        mediaFolder = ShowFolder.pick(chosen: chosen, appFolder: app, home: NSHomeDirectory(), listing: Self.listing) ?? ""
        mediaSource = mediaFolder.isEmpty ? ""
            : mediaFolder == chosen ? "chosen by hand"
            : mediaFolder == app ? "the folder tableauX is in"
            : "found by name"
        NSLog("folder: %@ (%@)", mediaFolder.isEmpty ? "none found" : mediaFolder, mediaSource)

        let shows = folderShows()
        if let path = ShowFolder.showToOpen(last: UserDefaults.standard.string(forKey: lastShowKey),
                                            folder: mediaFolder.isEmpty ? nil : mediaFolder,
                                            folderChosen: mediaFolder == chosen, folderShows: shows),
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
            // The folder decides (Mat): a show file in it = Conductor; works
            // but no show = Player; no folder at all = Standalone.
            mode = !shows.isEmpty ? .conductor : mediaFolder.isEmpty ? .standalone : .player
            NSLog("folder: role %@, from the folder", mode.rawValue)
        }
        // A conductor or standalone show opened with no works yet: fill it
        // from the folder, so a folder of works plays without a Scan.
        if mode != .player, show.works.isEmpty, !mediaFolder.isEmpty { scan() }
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
            let extra = FolderScan.assign(folder: folder, files: videos, displays: displays.count, firstScreen: firstScreen).leftOver
            if !extra.isEmpty { left[folder] = extra }
        }
        show.works = PlaylistMerge.merge(show.works, with: [Inventory(machine: name, displays: displays.count, folders: inventory)],
                                         firstScreens: [name: firstScreen])
        leftOver = left
        lastError = nil
        NSLog("scan: %d work(s) in %@", inventory.count, mediaFolder)
        fillNewDisplays()
        loadAllInfo()
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
            let (panels, left) = FolderScan.fill(set, folder: folder, files: files, displays: displays.count, firstScreen: firstScreen)
            if panels != set {
                show.works[w].screens[name] = panels
                NSLog("fill: %@ now on %d display(s)", show.works[w].name, panels.count)
            }
            leftOver[show.works[w].name] = left.isEmpty ? nil : left
        }
    }

    /// Reads the length etc. of every file this Mac plays, in every work.
    private func loadAllInfo() {
        for w in show.works.indices {
            panels(of: w).compactMap(\.file).map(resolve).filter(fileExists).forEach(loadInfo)
        }
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
                                   displays: displays.count, existing: Set(show.works.map(\.name)), firstScreen: firstScreen)
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
    func collectShow() {
        let showName = showPath?.deletingPathExtension().lastPathComponent ?? "Untitled"
        guard let dir = chooseCollectFolder() else { return }
        let root = dir.appendingPathComponent(Collect.uniqueName(showName, taken: Self.namesIn(dir)))
        collect(Array(show.works.indices), into: root, showFile: "\(showName).\(Self.showExtension)")
    }

    /// Copies this Mac's files for one work into a folder named after it:
    /// a folder that Import (or a scan) reads back as that work.
    func collectWork(_ w: Int) {
        guard show.works.indices.contains(w), let dir = chooseCollectFolder() else { return }
        collect([w], into: dir, showFile: nil)
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
    private func collect(_ indices: [Int], into root: URL, showFile: String?) {
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
                    let dest = root.appendingPathComponent(c.dest)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(atPath: c.source, toPath: dest.path)
                    await MainActor.run { self.collecting = "Collecting \(n + 1) of \(copies.count) files…" }
                }
                if let showFile, let showData { try showData.write(to: root.appendingPathComponent(showFile)) }
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
        // Find the folder, show and role (P4b), then start the clock exactly once.
        conductorAddress = UserDefaults.standard.string(forKey: addressKey) ?? ""
        findEverything()
        clockReady = true
        restartClock()
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
                playback.follow(s)
            } else if s.phase == .playing, s.version != dismissedVersion {
                startPlayback(following: s)
            }
        }
    }

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
            // Folding it in changes the show, whose didSet shares it again,
            // now with this player's files and lengths in it.
            show = SharedShow.merge(show, with: inv, conductor: Self.thisMac)
            scheduleShare()                  // lengths may change even if the show doesn't
        case .report(let machine, let blocking):
            players[id, default: PlayerLink()].machine = machine
            players[id]?.blocking = blocking
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
        show = s
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
        server?.broadcast()          // the once-a-second repeat of the show state
        if statusTicks % 5 == 0 { refreshInventory(); sendReport() }    // [claude] P3b, player only
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
        guard show.playOnLaunch else { return }
        Task {
            await infoLoaded()
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
        fillNewDisplays()
        guard let mi = machineIndex, show.machines[mi].displays != displays.count else { return }
        show.machines[mi].displays = displays.count
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
        if show.works.isEmpty { return (["Choose a media folder and Scan, or add a work."], []) }
        // [claude] Copying gigabytes while playing would compete with the
        // players for the disk; a collect is short and run by a person.
        if collecting != nil { blocking.append("Wait for the collect to finish.") }
        blocking += fileProblems()
        for (w, work) in show.works.enumerated() {
            if let extra = leftOver[work.name] {
                warnings.append("\(work.name): \(extra.count) file(s) not used on this Mac (more files than displays, or numbered for another screen): \(extra.joined(separator: ", ")).")
            }
            if panels(of: w).count > displays.count, panels(of: w).dropFirst(displays.count).contains(where: { $0.file != nil }) {
                warnings.append("\(work.name) has files for \(panels(of: w).count) displays but \(displays.count) are connected. The extra ones won't play.")
            }
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
        do {
            show = try ShowFile.decode(Data(contentsOf: url))
            showPath = url
            selectedWork = 0
            leftOver = [:]
            UserDefaults.standard.set(url.path, forKey: lastShowKey)
            refreshDisplays()
            // Only this Mac's files: the other machines' paths are on their disks.
            loadAllInfo()
        } catch {
            lastError = "Couldn't open \(url.lastPathComponent): \(error)"
        }
    }

    func saveDialog() {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: Self.showExtension) ?? .json]
        // Saving an old .msshow offers the same name with the new extension.
        let base = showPath?.deletingPathExtension().lastPathComponent ?? "Untitled"
        p.nameFieldStringValue = "\(base).\(Self.showExtension)"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try ShowFile.encode(show).write(to: url)
            showPath = url
            UserDefaults.standard.set(url.path, forKey: lastShowKey)
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
        let ordered = displays.compactMap { screens[$0.id] }
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
                          onWindowsUp: { [weak self] in self?.setupWindows.forEach { $0.orderOut(nil) } },
                          onEnd: { [weak self] in self?.playbackEnded() })
        playback = pb
        isPlaying = true
        pb.start(following: s.map { ($0.index, $0.start) })
    }

    func stop() { playback?.stop() }

    static let setupTitle = "tableauX"
    private var setupWindows: [NSWindow] {
        NSApp.windows.filter { !($0 is PanelWindow) && $0.title == Self.setupTitle }
    }

    private func playbackEnded() {
        if let failure = playback?.failure { lastError = failure; NSLog("%@", failure) }
        playback = nil
        isPlaying = false
        setupWindows.forEach { $0.makeKeyAndOrderFront(nil) }
        // [claude] The conductor's Esc ends the show everywhere.
        if mode == .conductor { server?.publish(ShowState(version: hostNanos(), phase: .stopped)) }
        // A player stopped by a person (not by the conductor) stays out of this state.
        if mode == .player, let current = follower.current, current.phase != .stopped {
            dismissedVersion = current.version
        }
    }
}
