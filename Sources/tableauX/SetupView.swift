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
                // refreshDisplays pads the show to one panel per display, but a
                // binding to an index past the end would crash, so check anyway.
                if i < model.show.panels.count {
                    PanelRow(number: i + 1, display: display,
                             panel: $model.show.panels[i], model: model)
                    Divider()
                }
            }
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
