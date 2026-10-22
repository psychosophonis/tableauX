import PlayerCore
import SwiftUI

/// The setup window (docs/architecture.md § UI): one row per connected display,
/// then problems, then the show's buttons.
///
/// The view holds no state of its own. Every control reads from and writes to
/// the AppModel through a BINDING (the `$model.show...` paths): a two-way
/// reference into the model, so flipping a toggle edits the show itself and
/// SwiftUI redraws whatever depends on it. Save writes exactly what is on
/// screen, because the screen is the model.
struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShowRow(model: model)
            MediaRow(model: model)
            // [claude] A fresh Mac: say what was made and what to do next.
            if model.libraryCreated, model.ownWorks.isEmpty {
                Text("tableauX made a library for you in Movies → \(ShowFolder.name). Put each work in a folder inside \(ShowFolder.worksName) (Show in Finder), then press Scan.")
                    .foregroundStyle(.secondary)
            }
            PlaylistList(model: model)
            Divider()
            if model.displays.isEmpty {
                Text("No displays found.").foregroundStyle(.secondary)
            }
            // [claude] The selected work's panels on this Mac. panels(of:)
            // pads to one per display; with no part for this Mac (or no
            // work) there are no rows, and the problem list says why.
            if model.show.works.indices.contains(model.selectedWork) {
                // [claude] P3b: on a player these show the conductor's
                // playlist, read-only: an edit here would be overwritten by
                // the next playlist the conductor sends.
                WorkSettingsRow(work: $model.show.works[model.selectedWork], length: model.length(of: model.selectedWork))
                    .disabled(model.mode == .player)
                // [claude] P4a: on the conductor, any Mac's screens.
                if model.mode == .conductor, !model.otherMachines.isEmpty {
                    Picker("Screens on", selection: $model.editingMachine) {
                        Text("This Mac").tag(String?.none)
                        ForEach(model.otherMachines, id: \.name) { Text($0.name).tag(String?.some($0.name)) }
                    }
                    .pickerStyle(.segmented)
                }
                if model.mode == .conductor, let m = model.editingMachine, model.otherMachines.contains(where: { $0.name == m }) {
                    RemoteScreens(model: model, machine: m)
                } else {
                    // [claude] Every display the show is DESIGNED for (Mat,
                    // 2026-10-22), connected here or not, so a laptop can
                    // set up and preview a 3-display Mac's part.
                    if model.mode != .player, let me = model.machineName {
                        Stepper("Displays in this show: \(model.designDisplays)",
                                value: Binding(get: { model.designDisplays }, set: { model.setDisplays(me, $0) }),
                                in: max(model.displays.count, 1)...16)
                            .help("How many displays this Mac has in the show's design. Displays not connected here can still be set up and previewed; a show plays on those that are connected.")
                    }
                    ForEach(0 ..< model.designDisplays, id: \.self) { i in
                        if i < model.panels.count {
                            PanelRow(number: i + 1, display: i < model.displays.count ? model.displays[i] : nil,
                                     panel: model.panelBinding(i), model: model)
                                .disabled(model.mode == .player)
                            Divider()
                        }
                    }
                }
            }
            SyncRow(sync: $model.show.sync)
            NetworkRow(model: model)
            ProblemList(problems: model.problems, lastError: model.lastError)
            HStack {
                Button("Open…") { model.openDialog() }.keyboardShortcut("o")
                Button("Save…") { model.saveDialog() }.keyboardShortcut("s")
                Toggle("Play on launch", isOn: $model.show.playOnLaunch)
                Spacer()
                // [claude] P4e: the whole tableau in one window, from this Mac's files.
                Button("Preview") { model.preview() }
                    .disabled(model.isPlaying || model.show.works.isEmpty)
                    .help("Play the show in one window: every screen of every Mac as a tile, a row per Mac, from the files on this Mac. For checking order, timing and assignment; a laptop may not decode a whole tableau smoothly.")
                Button("Play") { model.play() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isPlaying || !model.problems.blocking.isEmpty)
            }
            Text("During playback: Space pauses or resumes, → next work, ← previous work, Esc stops.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 640)
        .onAppear { model.launched() }
    }
}

/// One display and the panel that plays on it.
private struct PanelRow: View {
    let number: Int
    let display: DisplayInfo?           // [claude] nil: in the design, not connected here
    @Binding var panel: PanelConfig
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(display.map { "Display \(number): \($0.name)  ·  \(size($0.pixelSize))" }
                 ?? "Display \(number) (not connected here)")
                .font(.headline)
                .foregroundStyle(display == nil ? .secondary : .primary)
            HStack {
                fileLabel
                Spacer()
                Button("Choose…") { model.choose(panel: number - 1) }
                Button("Clear") { model.clear(panel: number - 1) }.disabled(panel.file == nil)
            }
            HStack(spacing: 16) {
                Toggle("Audio", isOn: $panel.audio).disabled(info?.hasAudio == false)
                Picker("Scaling", selection: $panel.scaling) {
                    Text("Fit").tag(Scaling.fit)
                    Text("Fill").tag(Scaling.fill)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                if let info { Text(details(info)).foregroundStyle(.secondary) }
            }
        }
    }

    private var info: MediaInfo? { panel.file.flatMap { model.media[model.resolve($0)] } }

    @ViewBuilder private var fileLabel: some View {
        if let file = panel.file {
            let path = model.resolve(file)
            let name = (path as NSString).lastPathComponent
            if model.fileExists(path) {
                Text(name).help(path)
            } else {
                Label("\(name) (missing)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).help(path)
            }
        } else {
            Text("No file: this display stays black").foregroundStyle(.secondary)
        }
    }

    /// e.g. "1920 × 1080 · 10.0 s · 2× on this display", plus "no audio track".
    ///
    /// The factor is computed against the display's real PIXELS, not its
    /// points, because pixels are what get resampled. A whole number (2×) means
    /// every source pixel maps to a clean block of screen pixels; anything else
    /// means the image is interpolated, which is worth knowing before a show.
    private func details(_ info: MediaInfo) -> String {
        var parts = [size(info.size), String(format: "%.1f s", info.duration)]
        if let display {                // the scale factor needs a real display to measure against
            parts.append("\(factor(Placement.scale(video: info.size, display: display.pixelSize, scaling: panel.scaling))) on this display")
        }
        if !info.hasAudio { parts.append("no audio track") }
        return parts.joined(separator: "  ·  ")
    }

    private func size(_ s: CGSize) -> String { "\(Int(s.width)) × \(Int(s.height))" }

    private func factor(_ s: CGFloat) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%.2f×", Double(s))
    }
}

/// [claude] P4a: another Mac's screens for the selected work, set from the
/// conductor using the files that Mac reported (§ Getting works in › Manual).
/// The file menu is the whole of that Mac's media folder, so a screen can
/// take any of its files, from any folder: the way to fix files that were
/// named or numbered wrongly without visiting the Mac.
private struct RemoteScreens: View {
    @ObservedObject var model: AppModel
    let machine: String

    var body: some View {
        let files = model.reportedFiles(of: machine)
        VStack(alignment: .leading, spacing: 8) {
            if model.inventory(of: machine) == nil {
                Text("\(machine) hasn't reported its files since this Mac became Conductor, so they aren't listed. Its saved screens are shown.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.isConnected(machine) {
                Text("\(machine) isn't connected: its files are as it last reported them. Changes reach it when it reconnects.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // [claude] The design's count for that Mac (never shrunk by a report).
            let count = model.show.machines.first(where: { $0.name == machine })?.displays ?? 0
            Stepper("Displays in this show: \(count)",
                    value: Binding(get: { count }, set: { model.setDisplays(machine, $0) }), in: 1...16)
            let panels = model.panels(on: machine)
            if panels.isEmpty { Text("\(machine) has reported no displays yet.").foregroundStyle(.secondary) }
            ForEach(panels.indices, id: \.self) { i in
                RemotePanelRow(number: i + 1, machine: machine, files: files, panel: model.panelBinding(on: machine, i))
                Divider()
            }
        }
    }
}

private struct RemotePanelRow: View {
    let number: Int
    let machine: String
    let files: [(path: String, file: InventoryFile)]
    @Binding var panel: PanelConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(machine), display \(number)").font(.headline)
            HStack(spacing: 16) {
                Picker("File", selection: $panel.file) {
                    Text("None: this display stays black").tag(String?.none)
                    // A saved file the Mac no longer reports stays visible,
                    // marked, rather than silently vanishing from the menu.
                    if let f = panel.file, !files.contains(where: { $0.path == f }) {
                        Text("\(f) (not reported)").tag(String?.some(f))
                    }
                    ForEach(files, id: \.path) { Text($0.path).tag(String?.some($0.path)) }
                }
                .frame(maxWidth: 420)
                Toggle("Audio", isOn: $panel.audio).disabled(info?.hasAudio == false)
                Picker("Scaling", selection: $panel.scaling) {
                    Text("Fit").tag(Scaling.fit)
                    Text("Fill").tag(Scaling.fill)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            if let info {
                Text(String(format: "%.1f s  ·  %.0f fps%@", info.duration, info.fps, info.hasAudio ? "" : "  ·  no audio track"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var info: InventoryFile? { panel.file.flatMap { f in files.first(where: { $0.path == f })?.file } }
}

/// [claude] P4d: which show is open, and switching between the library's
/// shows (§ Library: works and shows). On a conductor, switching sends the
/// new show to every player; on a player the menu is off (it follows).
private struct ShowRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Text("Show:").font(.headline)
            Menu(model.showName) {
                ForEach(model.showFiles, id: \.self) { path in
                    Button((path as NSString).lastPathComponent.replacingOccurrences(of: ".\(AppModel.showExtension)", with: "")) {
                        model.open(URL(fileURLWithPath: path))
                    }
                }
                if !model.showFiles.isEmpty { Divider() }
                Button("New show…") { model.newShow() }
                Button("Open another…") { model.openDialog() }
            }
            .frame(maxWidth: 360)
            .disabled(model.mode == .player)
            .help("Shows in this library. A new show starts with every work; remove, add and reorder from there.")
            Spacer()
        }
    }
}

/// [claude] This Mac's media folder and the Scan button (§ v4 › Getting
/// works in). A setting of this Mac, not of the show, like the mode.
private struct MediaRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Text("Library:")
            // [claude] P4b: say where the folder came from, or where it was
            // looked for, so a Mac that found nothing says what to do.
            // P4d: it is a library now (Works/ and Shows/, or works directly).
            Text(model.libraryFolder.isEmpty
                 ? "no \(ShowFolder.name) folder found (looked in and beside the app's folder, and in your home folder, Movies and Desktop)"
                 : model.libraryFolder)
                .foregroundStyle(model.libraryFolder.isEmpty ? .secondary : .primary)
                .lineLimit(1).truncationMode(.head)
                .help(model.libraryFolder.isEmpty ? "" : "\(model.libraryFolder): \(model.mediaSource). Works: \(model.mediaFolder)")
            Spacer()
            Button("Show in Finder") { model.revealLibrary() }.disabled(model.libraryFolder.isEmpty)
                .help("Open the library's Works folder: one folder per work goes in here.")
            Button("Choose…") { model.chooseMediaFolder() }
            Button("Scan") { model.scan() }.disabled(model.mediaFolder.isEmpty)
                .help("Re-read the library's works. Files go on screens by their _N number, else in name order. Only the unsaved all-works show gains new works; add them to a saved show with Add from library.")
            Button("Import folder…") { model.importFolder() }
                .disabled(model.mode == .player)      // a player's works come from the conductor
                .help("Add works from a folder anywhere, linked where they are (not copied). The folder's own videos are one work; each folder inside it is another.")
        }
    }
}

/// [claude] The playlist: one line per work, click to edit its panels below.
/// Basic for now (P2); the full editor and jump-to are P4.
private struct PlaylistList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Playlist").font(.headline)
                Spacer()
                Stepper(String(format: "Gap: %.0f s", model.show.playlist.gap), value: $model.show.playlist.gap, in: 0...30, step: 1)
                    .help("Black between works, while the next one loads.")
                Toggle("Loop", isOn: $model.show.playlist.loop)
                    .help("Back to the first work after the last.")
            }
            .disabled(model.mode == .player)
            if model.mode == .player {
                Text("This is the conductor's playlist. Change it on the conductor; Scan here sends this Mac's files to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.show.works.enumerated()), id: \.offset) { w, work in
                HStack {
                    Text("\(w + 1). \(work.name)")
                        .fontWeight(w == model.selectedWork ? .bold : .regular)
                    Text(summary(w, work)).foregroundStyle(.secondary)
                    Spacer()
                    if w == model.selectedWork {
                        Group {
                            Button("↑") { model.moveWork(w, by: -1) }.disabled(w == 0)
                            Button("↓") { model.moveWork(w, by: 1) }.disabled(w == model.show.works.count - 1)
                            Button("Remove") { model.removeWork(w) }
                                .help("Remove from this show. The work's files stay in the library.")
                        }
                        .disabled(model.mode == .player)
                        Button("Collect…") { model.collectWork(w) }.disabled(model.collecting != nil)
                            .help("Copy this work's files on this Mac into one folder, for archiving.")
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedWork = w }
                .background(w == model.selectedWork ? Color.accentColor.opacity(0.12) : .clear)
            }
            HStack {
                // [claude] P4d: works come from the library pool; a work in
                // several shows is still one folder.
                Menu("Add from library") {
                    ForEach(model.worksToAdd, id: \.self) { name in
                        Button(name) { model.addFromLibrary(name) }
                    }
                    if model.worksToAdd.count > 1 {
                        Divider()
                        Button("All \(model.worksToAdd.count) works") { model.addAllFromLibrary() }
                    }
                }
                .fixedSize()
                .disabled(model.mode == .player || model.worksToAdd.isEmpty)
                .help("Works in the library (on any Mac) that this show doesn't have yet.")
                Button("Add work") { model.addWork() }
                    .help("A work set up by hand: choose its files below.")
                    .disabled(model.mode == .player)
                Spacer()
                if let progress = model.collecting { Text(progress).foregroundStyle(.secondary) }
                Button("Collect show…") { model.collectShow() }
                    .disabled(model.collecting != nil || model.show.works.isEmpty)
                    .help("Copy every work's files on this Mac into one folder, with a copy of the show that plays from it. Each Mac collects its own files.")
            }
        }
    }

    /// e.g. "2 files · 60.0 s · once · shorter: black"
    private func summary(_ w: Int, _ work: Work) -> String {
        let files = model.panels(of: w).compactMap(\.file).count
        let length = model.length(of: w)
        var parts = ["\(files) file\(files == 1 ? "" : "s")"]
        parts.append(length > 0 ? String(format: "%.1f s", length) : "no length yet")
        switch work.repeat {
        case .times(1): parts.append("once")
        case .times(let n): parts.append("\(n) times")
        case .untilNext: parts.append("until moved on")
        }
        parts.append("shorter: \(work.shorter.rawValue)")
        return parts.joined(separator: "  ·  ")
    }
}

/// [claude] The selected work's own settings (§ v4 › Playing): how often it
/// plays, and what its shorter screens do.
private struct WorkSettingsRow: View {
    @Binding var work: Work
    let length: Double

    var body: some View {
        HStack(spacing: 16) {
            TextField("Name", text: $work.name).frame(width: 160)
                .help("For a scanned work this is the folder name, which joins it across Macs.")
            Toggle("Until moved on", isOn: untilNext)
            if case .times(let n) = work.repeat {
                Stepper("Plays \(n == 1 ? "once" : "\(n) times")", value: times(n), in: 1...99)
            }
            Picker("Shorter screens", selection: $work.shorter) {
                Text("Go black").tag(Shorter.black)
                Text("Loop").tag(Shorter.loop)
            }
            .frame(width: 230)
        }
    }

    private var untilNext: Binding<Bool> {
        Binding(get: { work.repeat == .untilNext }, set: { work.repeat = $0 ? .untilNext : .once })
    }

    private func times(_ n: Int) -> Binding<Int> {
        Binding(get: { n }, set: { work.repeat = .times($0) })
    }
}

/// [claude] The show's sync settings (§ Sync › Drift check). The ranges are
/// the file's rules (tolerance ≥ 1, grace ≥ 0) with an upper end a person
/// would sensibly use; a hand-edited file outside them still opens.
private struct SyncRow: View {
    @Binding var sync: SyncSettings

    var body: some View {
        HStack(spacing: 24) {
            Stepper("Sync tolerance: \(sync.tolerance) frame\(sync.tolerance == 1 ? "" : "s")",
                    value: $sync.tolerance, in: 1...30)
            Stepper(String(format: "Grace: %.0f s", sync.grace), value: $sync.grace, in: 0...60, step: 1)
        }
        .help("A panel more than the tolerance out for the grace period is put back with a seek. 1 frame, 0 s is the tightest.")
    }
}

/// [claude] This Mac's network mode (v3 § One app, three modes) and the
/// clock's status. Until Stage 3, Conductor and Player run only the clock;
/// playback still follows this Mac's own clock.
private struct NetworkRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("This Mac", selection: $model.mode) {
                    ForEach(AppModel.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                if model.mode == .player {
                    TextField("Conductor's address", text: $model.conductorAddress)
                        .frame(width: 180)
                        .onSubmit { model.restartClock() }
                }
            }
            if !model.clockStatus.isEmpty {
                Text(model.clockStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            // [claude] P3b: the playlist link, beside the clock.
            if model.mode == .conductor {
                Text(model.playerLines.isEmpty ? "Playlist link: no players connected." : "Players: " + model.playerLines.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.mode == .player {
                Text(model.sharedLengths.map { "Playing the conductor's playlist: \($0.count) work\($0.count == 1 ? "" : "s")." }
                     ?? (model.linkUp ? "Connected; waiting for the conductor's playlist…" : "Playlist link: connecting to the conductor…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// What stops playback (red) and what deserves a look (orange).
private struct ProblemList: View {
    let problems: (blocking: [String], warnings: [String])
    let lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems.blocking, id: \.self) { Text($0).foregroundStyle(.red) }
            ForEach(problems.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
            if let lastError { Text(lastError).foregroundStyle(.red) }
        }
    }
}
