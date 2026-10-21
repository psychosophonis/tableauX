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
            MediaRow(model: model)
            PlaylistList(model: model)
            Divider()
            if model.displays.isEmpty {
                Text("No displays found.").foregroundStyle(.secondary)
            }
            // [claude] The selected work's panels on this Mac. panels(of:)
            // pads to one per display; with no part for this Mac (or no
            // work) there are no rows, and the problem list says why.
            if model.show.works.indices.contains(model.selectedWork) {
                WorkSettingsRow(work: $model.show.works[model.selectedWork], length: model.length(of: model.selectedWork))
                ForEach(Array(model.displays.enumerated()), id: \.element.id) { i, display in
                    if i < model.panels.count {
                        PanelRow(number: i + 1, display: display, panel: model.panelBinding(i), model: model)
                        Divider()
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
    let display: DisplayInfo
    @Binding var panel: PanelConfig
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Display \(number): \(display.name)  ·  \(size(display.pixelSize))")
                .font(.headline)
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
        let scale = Placement.scale(video: info.size, display: display.pixelSize, scaling: panel.scaling)
        var parts = [size(info.size), String(format: "%.1f s", info.duration), "\(factor(scale)) on this display"]
        if !info.hasAudio { parts.append("no audio track") }
        return parts.joined(separator: "  ·  ")
    }

    private func size(_ s: CGSize) -> String { "\(Int(s.width)) × \(Int(s.height))" }

    private func factor(_ s: CGFloat) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%.2f×", Double(s))
    }
}

/// [claude] This Mac's media folder and the Scan button (§ v4 › Getting
/// works in). A setting of this Mac, not of the show, like the mode.
private struct MediaRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Text("Media folder:")
            Text(model.mediaFolder.isEmpty ? "none chosen" : model.mediaFolder)
                .foregroundStyle(model.mediaFolder.isEmpty ? .secondary : .primary)
                .lineLimit(1).truncationMode(.head)
                .help(model.mediaFolder)
            Spacer()
            Button("Choose…") { model.chooseMediaFolder() }
            Button("Scan") { model.scan() }.disabled(model.mediaFolder.isEmpty)
                .help("Each subfolder is a work; its videos go on the displays in name order.")
            Button("Import folder…") { model.importFolder() }
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
            ForEach(Array(model.show.works.enumerated()), id: \.offset) { w, work in
                HStack {
                    Text("\(w + 1). \(work.name)")
                        .fontWeight(w == model.selectedWork ? .bold : .regular)
                    Text(summary(w, work)).foregroundStyle(.secondary)
                    Spacer()
                    if w == model.selectedWork {
                        Button("↑") { model.moveWork(w, by: -1) }.disabled(w == 0)
                        Button("↓") { model.moveWork(w, by: 1) }.disabled(w == model.show.works.count - 1)
                        Button("Remove") { model.removeWork(w) }
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
                Button("Add work") { model.addWork() }
                    .help("A work set up by hand: choose its files below.")
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
