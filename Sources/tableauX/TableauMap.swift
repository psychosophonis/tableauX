import PlayerCore
import SwiftUI

// [claude] Interface step 1 (Mat, 2026-10-22: "a good hard look at the
// accretion of features"). The selected work's screens drawn as the
// TABLEAU: a row per Mac, in the show's order, a 16:9 tile per display it
// is designed for, numbered across the whole tableau. The same layout as the
// preview window, so what you set up is what you see play.
//
// It replaces three things that grew separately: the list of this Mac's
// displays, the "Screens on" switcher, and the other Macs' rows. Each tile
// opens an editor for its screen; which Mac it belongs to decides only where
// the file menu comes from (this Mac's library, or what that Mac reported).

struct TableauMap: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.show.machines, id: \.name) { m in
                MachineRow(model: model, machine: m.name)
            }
            if model.show.machines.isEmpty {
                Text("No Mac in this show yet.").foregroundStyle(.secondary)
            }
        }
    }
}

/// [claude] The show's tableau: how many displays each Mac has in this show,
/// for EVERY work (a triptych is three screens whatever plays on it). A work
/// with fewer screens leaves the rest black (a tile set to None).
struct TableauSizeRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Tableau:").font(.headline)
            ForEach(model.show.machines, id: \.name) { m in
                let isThisMac = m.name == model.machineName
                let count = isThisMac ? model.designDisplays : m.displays
                Stepper("\(m.name): \(count) display\(count == 1 ? "" : "s")",
                        value: Binding(get: { count }, set: { model.setDisplays(m.name, $0) }),
                        in: (isThisMac ? max(model.displays.count, 1) : 1)...16)
                    .fixedSize()
            }
            Spacer()
            Text("for every work in this show; a work with fewer screens leaves the rest black")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .disabled(model.mode == .player)
        .help("How many displays each Mac has in this show's design, the same for every work. Screens not connected here can still be set up and previewed. For a work with fewer screens, click a screen below and choose None.")
    }
}

/// One Mac: its name, its state, its screens for the selected work.
private struct MachineRow: View {
    @ObservedObject var model: AppModel
    let machine: String

    private var isThisMac: Bool { machine == model.machineName }
    private var count: Int {
        isThisMac ? model.designDisplays : (model.show.machines.first { $0.name == machine }?.displays ?? 0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(machine).font(.headline).lineLimit(1).help(machine)
                Text(isThisMac ? "this Mac · \(state)" : state).font(.caption).foregroundStyle(.secondary)
                // [claude] No display count here: it is the SHOW's, the same
                // for every work (Mat's triptych), so it lives in the
                // Tableau row under the Show menu. A stepper beside one
                // work's screens read as that work's count, and setting a
                // 2-screen work to 2 hid screen 3 of every work (2026-10-22).
            }
            .frame(width: 170, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0 ..< count, id: \.self) { i in
                        ScreenTile(model: model, machine: machine, index: i)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var state: String {
        if isThisMac { return "\(min(model.displays.count, count)) of \(count) connected here" }
        if model.isConnected(machine) { return "connected" }
        return model.inventory(of: machine) == nil ? "not heard from yet" : "not connected"
    }
}

/// One screen of the selected work: a tile that opens its editor.
private struct ScreenTile: View {
    @ObservedObject var model: AppModel
    let machine: String
    let index: Int
    @State private var editing = false

    private var isThisMac: Bool { machine == model.machineName }
    private var panel: Binding<PanelConfig> {
        isThisMac ? model.panelBinding(index) : model.panelBinding(on: machine, index)
    }
    private var screen: Int { SharedShow.firstScreen(model.show, of: machine) + index }
    private var connected: Bool { !isThisMac || index < model.displays.count }

    /// A file this screen can't play: missing on this Mac, or not among what
    /// that Mac reported.
    private var missing: Bool {
        guard let f = panel.wrappedValue.file else { return false }
        if isThisMac { return !model.fileExists(model.resolve(f)) }
        let reported = model.reportedFiles(of: machine)
        return !reported.isEmpty && !reported.contains { $0.path == f }
    }

    var body: some View {
        Button { editing = true } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(screen)").font(.caption.bold()).foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 0)
                    Text(fileName).font(.caption).foregroundStyle(panel.wrappedValue.file == nil ? .white.opacity(0.4) : .white)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if panel.wrappedValue.audio { Image(systemName: "speaker.wave.2.fill") }
                        if panel.wrappedValue.scaling == .fill { Text("Fill") }
                        if !connected { Text("not here") }
                    }
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
                .padding(6)
            }
            .frame(width: 150, height: 84)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(missing ? Color.red : (editing ? Color.accentColor : Color.gray.opacity(connected ? 0.6 : 0.35)),
                              style: StrokeStyle(lineWidth: missing || editing ? 2 : 1, dash: connected ? [] : [4, 3])))
        }
        .buttonStyle(.plain)
        .help("\(machine) · display \(index + 1) · screen \(screen)" + (missing ? " · file not found" : ""))
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            ScreenEditor(model: model, machine: machine, index: index, screen: screen, panel: panel)
                .disabled(model.mode == .player)
        }
    }

    private var fileName: String {
        guard let f = panel.wrappedValue.file else { return "black" }
        return ((f as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// The editor for one screen: its file, audio and scaling, and what is known
/// about the file. The file menu lists that Mac's files: this Mac's library,
/// or what a player reported (any folder: the way to fix files named or
/// numbered wrongly without visiting the Mac).
private struct ScreenEditor: View {
    @ObservedObject var model: AppModel
    let machine: String
    let index: Int
    let screen: Int
    @Binding var panel: PanelConfig

    private var isThisMac: Bool { machine == model.machineName }
    private var files: [String] { isThisMac ? model.ownFiles : model.reportedFiles(of: machine).map(\.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(machine) · display \(index + 1) · screen \(screen)").font(.headline)
            Picker("File", selection: $panel.file) {
                Text("None: this screen stays black").tag(String?.none)
                // A file not in the list (linked from elsewhere, or no longer
                // reported) stays visible, marked, rather than vanishing.
                if let f = panel.file, !files.contains(f) {
                    Text("\((f as NSString).lastPathComponent) (\(isThisMac ? "elsewhere" : "not reported"))").tag(String?.some(f))
                }
                ForEach(files, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            if isThisMac {
                Button("Choose a file anywhere…") { model.choose(panel: index) }
                    .help("A file outside the library is linked where it is; Collect gathers it later.")
            }
            HStack(spacing: 16) {
                Toggle("Audio", isOn: $panel.audio)
                Picker("", selection: $panel.scaling) {
                    Text("Fit").tag(Scaling.fit)
                    Text("Fill").tag(Scaling.fill)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            if let details { Text(details).font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
        .frame(width: 380)
    }

    /// e.g. "1920 × 1080 · 12.0 s · 2× on this display" for this Mac, or
    /// "12.0 s · 30 fps" from a player's report.
    private var details: String? {
        guard let f = panel.file else { return nil }
        if isThisMac {
            guard let info = model.media[model.resolve(f)] else { return model.fileExists(model.resolve(f)) ? "Reading the file…" : "File not found." }
            var parts = ["\(Int(info.size.width)) × \(Int(info.size.height))", String(format: "%.1f s", info.duration)]
            if index < model.displays.count {
                let s = Placement.scale(video: info.size, display: model.displays[index].pixelSize, scaling: panel.scaling)
                parts.append((s == s.rounded() ? "\(Int(s))×" : String(format: "%.2f×", Double(s))) + " on this display")
            }
            if !info.hasAudio { parts.append("no audio track") }
            return parts.joined(separator: "  ·  ")
        }
        guard let r = model.reportedFiles(of: machine).first(where: { $0.path == f })?.file else { return "Not among the files \(machine) reported." }
        return String(format: "%.1f s  ·  %.0f fps", r.duration, r.fps) + (r.hasAudio ? "" : "  ·  no audio track")
    }
}
