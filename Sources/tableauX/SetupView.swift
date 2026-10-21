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
            if model.displays.isEmpty {
                Text("No displays found.").foregroundStyle(.secondary)
            }
            ForEach(Array(model.displays.enumerated()), id: \.element.id) { i, display in
                // refreshDisplays pads this Mac's part to one panel per display,
                // but a binding to an index past the end would crash, so check
                // anyway. With no part for this Mac there are no rows; the
                // problem list says why.
                if let mi = model.machineIndex, i < model.show.machines[mi].panels.count {
                    PanelRow(number: i + 1, display: display,
                             panel: $model.show.machines[mi].panels[i], model: model)
                    Divider()
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
            Text("During playback: Space pauses or resumes, Esc stops.")
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

    private var info: MediaInfo? { panel.file.flatMap { model.media[$0] } }

    @ViewBuilder private var fileLabel: some View {
        if let path = panel.file {
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
