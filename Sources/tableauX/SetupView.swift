import PlayerCore
import SwiftUI

/// The setup window, i.e. Compose (docs/architecture.md § v4 › Compose and
/// Present): the show and its works, the selected work's screens as the
/// tableau, then this Mac's settings and one status line.
///
/// The view holds no state of its own. Every control reads from and writes to
/// the AppModel through a BINDING (the `$model.show...` paths): a two-way
/// reference into the model, so flipping a toggle edits the show itself and
/// SwiftUI redraws whatever depends on it. A named show saves itself, so what
/// is on screen is what is in the file.
///
/// [claude] Interface step 1 (Mat, 2026-10-22): the per-display list, the
/// "Screens on" switcher and the other Macs' rows became the TableauMap; the
/// red and orange problem sentences became the StatusLine; the Scan button
/// went (the library is re-read by itself).
struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // [claude] Launch indicator (Mat, 2026-10-22): what tableauX is
            // doing while it finds the library and measures the videos.
            if let status = model.startupStatus {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(status)
                    Spacer()
                    Button("Skip") { model.skipStartup() }
                        .help("Stop waiting: the window is usable at once (videos are still measured in the background), and a show set to start presenting by itself won't, this time.")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
            }
            ShowRow(model: model)
            TableauSizeRow(model: model)        // [claude] the show's display counts, for every work
            MediaRow(model: model)
            // [claude] A fresh Mac: say what was made and what to do next.
            if model.libraryCreated, model.ownWorks.isEmpty {
                Text("tableauX made a library for you in Movies → \(ShowFolder.name). Put each work in a folder inside \(ShowFolder.worksName) (Show in Finder); it appears here by itself.")
                    .foregroundStyle(.secondary)
            }
            PlaylistList(model: model)
            Divider()
            if model.show.works.indices.contains(model.selectedWork) {
                // [claude] P3b: on a player these show the conductor's
                // playlist, read-only: an edit here would be overwritten by
                // the next playlist the conductor sends.
                WorkSettingsRow(work: $model.show.works[model.selectedWork], length: model.length(of: model.selectedWork))
                    .disabled(model.mode == .player)
                TableauMap(model: model)
            }
            Divider()
            SyncRow(sync: $model.show.sync)
            NetworkRow(model: model)
            StatusLine(model: model)
            HStack {
                // [claude] A named show saves itself (autosave); this makes a
                // copy under a new name. Only the unsaved all-works show
                // needs naming once: then it reads "Save…". (Open… and
                // "Open in Present mode" moved into the Show menu: Mat's
                // review, 2026-10-22.)
                Button(model.showPath == nil ? "Save…" : "Save As…") { model.saveDialog() }.keyboardShortcut("s")
                    .help(model.showPath == nil ? "Name this show and save it into the library's Shows folder. From then on it saves itself."
                                                : "Changes save themselves. Save As… makes a copy under a new name.")
                Spacer()
            }
            Text("Presenting or previewing: Space pauses or resumes, → next work, ← previous work, Esc comes back here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 760)
        .onAppear {
            model.launched()
            // [claude] Nothing focused when the window opens: SwiftUI focused
            // the first text field (the work's name), so typing meant for
            // another app renamed a work (seen 2026-10-22).
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }
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
                Button("Open a show from elsewhere…") { model.openDialog() }
                Divider()
                // [claude] Mat's review (2026-10-22): off the main window;
                // only an unattended gallery Mac needs these.
                Toggle("Start presenting when tableauX opens", isOn: $model.show.playOnLaunch)
                Button("Export show as a library…") { model.exportShow() }
                    .disabled(model.collecting != nil || model.show.works.isEmpty)
            }
            .frame(maxWidth: 360)
            .disabled(model.mode == .player)
            .help("Shows in this library. A new show starts with every work; remove, add and reorder from there.")
            Spacer()
            // [claude] Compose and Present (Mat, 2026-10-22). This window is
            // Compose; Preview plays the whole tableau in a window; Present
            // plays it full screen on the real displays (Esc comes back).
            Button("Preview") { model.preview() }
                .disabled(model.isPlaying || model.show.works.isEmpty)
                .help("Play the show in a window: every screen of every Mac as a tile, a row per Mac, from the files on this Mac. For checking order, timing and assignment; a laptop may not decode a whole tableau smoothly.")
            // [claude] Mat's review (2026-10-22): no Compose switch, the
            // window is where you compose; two plain actions.
            if model.mode == .player {
                Text("Presents when the conductor does").foregroundStyle(.secondary)
            } else {
                Button(presentLabel) { model.play() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isPlaying || !model.problems.blocking.isEmpty)
                    .help("Play the show full screen on this Mac's displays (and, as Conductor, on every player). Esc comes back here.")
            }
        }
    }

    /// "Present", or "Present (1 of 3 displays)" when fewer are connected
    /// than the show is designed for, so it's clear before pressing.
    private var presentLabel: String {
        model.displays.count < model.designDisplays
            ? "Present (\(model.displays.count) of \(model.designDisplays) displays)" : "Present"
    }
}

/// [claude] This Mac's library (§ v4 › Library). A setting of this Mac, not
/// of the show, like the mode. No Scan button since interface step 1: the
/// library is re-read when the app comes back to the front and every 5 s.
private struct MediaRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Text("Library:")
            // [claude] P4b: say where the folder came from, or where it was
            // looked for, so a Mac that found nothing says what to do.
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
            Button("Import work…") { model.importFolder() }
                .disabled(model.mode == .player)      // a player's works come from the conductor
                .help("Choose a folder of videos: it becomes a work, linked where it is (not copied); Collect brings it into the library later. A folder of folders brings in one work per folder.")
        }
    }
}

/// [claude] The playlist: one line per work, click to edit its screens below.
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
                Text("This is the conductor's show. Change it on the conductor; this Mac's files reach it by themselves.")
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
                        Button("Collect") { model.collectWork(w) }.disabled(model.collecting != nil)
                            .help("Bring this work's files that live outside the library into its Works folder. Files already in the library stay put.")
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
                Button("New work") { model.addWork() }
                    .help("A work set up by hand: choose its files on the screens below.")
                    .disabled(model.mode == .player)
                Spacer()
                if let progress = model.collecting { Text(progress).foregroundStyle(.secondary) }
                Button("Collect show") { model.collectShow() }
                    .disabled(model.collecting != nil || model.show.works.isEmpty)
                    .help("Bring every file this show uses from outside the library into Works/, so the library holds the whole show. Files already in the library stay put. (To copy the show somewhere else, use Export in the Show menu.)")
            }
        }
    }

    /// e.g. "2 of 3 screens · 60.0 s · once · shorter: black"
    ///
    /// [claude] Counted over the whole tableau (every Mac, each to its
    /// designed count, as the preview lays it out), so a 2-screen work on a
    /// triptych reads differently from a 3-screen one (Mat, 2026-10-22: "the
    /// playlist doesn't reflect this difference"). It used to count every
    /// stored file on this Mac, including screens beyond the tableau.
    private func summary(_ w: Int, _ work: Work) -> String {
        let tiles = PreviewLayout.rows(model.show, work: work).flatMap { $0 }
        let used = tiles.filter { $0.panel.file != nil }.count
        let length = model.length(of: w)
        var parts = [tiles.count == used ? "\(used) screen\(used == 1 ? "" : "s")" : "\(used) of \(tiles.count) screens"]
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

/// [claude] This Mac's network mode (v3 § One app, three modes) and, for a
/// player, the conductor's address. Its state is in the status line (step 1).
private struct NetworkRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Picker("This Mac", selection: $model.mode) {
                ForEach(AppModel.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            if model.mode == .player {
                TextField("Conductor's address (blank: find it)", text: $model.conductorAddress)
                    .frame(width: 240)
                    .onSubmit { model.restartClock() }
            }
        }
    }
}
