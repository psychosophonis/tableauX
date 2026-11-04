import AppKit
import PlayerCore
import SwiftUI

// [claude] v5: the selected work's sound, as a table per Mac (docs/architecture.md
// § Getting sound in, § A stereo file meant for one speaker). Sound files and
// screens' videos sit in the same table because they are the same thing here: a
// source sent to an output. Each row says how the app read the source, since that
// reading can be wrong and a person is the check on it.

struct SoundPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sound: SoundPrep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sound").font(.headline)
            ForEach(model.show.machines, id: \.name) { m in
                if m.name == model.machineName || !model.routes(on: m.name).isEmpty {
                    MacSound(model: model, sound: sound, machine: m.name)
                }
            }
        }
    }
}

private struct MacSound: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sound: SoundPrep
    let machine: String

    private var isThisMac: Bool { machine == model.machineName }
    private var routes: [AudioRoute] { model.routes(on: machine) }
    private var state: SoundState? { model.soundState(machine: machine, work: model.selectedWork) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(model.displayName(of: machine)).font(.subheadline.bold())
                if isThisMac { devicePicker }
                addMenu
                Spacer()
            }
            if routes.isEmpty {
                Text("No sound set. Put files in this work's \(AudioScan.folderName) folder (name_3.wav goes to output 3), or send a screen's video to an output.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Rows are identified by POSITION, not by a stable id, which is SwiftUI's
            // weak spot: removing a row makes the next one inherit its view state.
            // Acceptable here because a row holds no state of its own (every value
            // is read from the show), so there's nothing to inherit.
            ForEach(routes.indices, id: \.self) { row(at: $0) }
            if let state, isThisMac {
                ForEach(state.plan.problems + state.plan.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                switch state.status {
                case .baking: Text("Preparing the sound…").font(.caption).foregroundStyle(.secondary)
                case .failed(let why): Text(why).font(.caption).foregroundStyle(.red)
                default: EmptyView()
                }
            }
        }
        .disabled(!model.canEditScreens(of: machine))
    }

    private func row(at i: Int) -> some View {
        let r = routes[i]
        return HStack(spacing: 10) {
            Text(AudioRouting.name(r)).frame(width: 170, alignment: .leading).lineLimit(1).truncationMode(.middle)
            Stepper(r.output == 0 ? "Off" : "Output \(r.output)",
                    value: Binding(get: { r.output }, set: { set(i) { $0.output = $1 }($0) }), in: 0...64)
                .frame(width: 120, alignment: .leading)
                .help("Which output of this Mac's interface it starts on. Off keeps it silent.")
            Picker("", selection: Binding(get: { r.take }, set: { set(i) { $0.take = $1 }($0) })) {
                Text("Automatic").tag(AudioTake.auto)
                Text("Pair").tag(AudioTake.pair)
                Text("Sum to one").tag(AudioTake.sum)
                Text("Left").tag(AudioTake.left)
                Text("Right").tag(AudioTake.right)
            }
            .frame(width: 120)
            .help("Automatic reads the file: a dual-mono or one-sided file takes one speaker. It can guess wrong, so check the note beside it.")
            Text(line(i)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            // A folder's file would only come back on the next rescan; Off is how
            // to silence one. A screen or a linked file can really go.
            if r.screen != nil || r.file?.hasPrefix("/") == true {
                Button { remove(i) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
            }
        }
    }

    /// The route's reading. For another Mac whose file isn't here, it can't be read.
    private func line(_ i: Int) -> String {
        guard let lines = state?.plan.lines, i < lines.count else { return "" }
        if !isThisMac, lines[i].hasSuffix("reading the file…") { return "read on that Mac" }
        return lines[i]
    }

    /// A function that returns a function (CURRYING): `set(i) { $0.output = $1 }` is
    /// "the setter for row i's output", ready to go in a Binding. Routes live in a
    /// dictionary inside the show, out of reach of SwiftUI's `$` paths, so each
    /// control needs a hand-written setter, and this keeps them to one line.
    ///
    /// A VALUE-TYPE UPDATE: copy the array, change the copy, hand back the whole
    /// thing. It goes through `setRoutes` every time, which is the single place that
    /// also tells the conductor when this Mac is a player.
    private func set<T>(_ i: Int, _ change: @escaping (inout AudioRoute, T) -> Void) -> (T) -> Void {
        { value in
            var all = routes
            guard i < all.count else { return }
            change(&all[i], value)
            model.setRoutes(all, on: machine)
        }
    }

    private func remove(_ i: Int) {
        var all = routes
        guard i < all.count else { return }
        all.remove(at: i)
        model.setRoutes(all, on: machine)
    }

    private func nextOutput() -> Int {
        let taken = Set(routes.map(\.output))
        return (1...).first { !taken.contains($0) } ?? 1
    }

    /// Adds a screen's video to the table, or on this Mac a file from anywhere.
    private var addMenu: some View {
        Menu("Add") {
            let count = model.show.machines.first { $0.name == machine }?.screenCount ?? 0
            let used = Set(routes.compactMap(\.screen))
            ForEach(0..<count, id: \.self) { s in
                if !used.contains(s) {
                    Button("Screen \(SharedShow.firstScreen(model.show, of: machine) + s)'s video") {
                        model.setRoutes(routes + [AudioRoute(screen: s, output: nextOutput())], on: machine)
                    }
                }
            }
            if isThisMac {
                Button("A sound file…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.audio]
                    if p.runModal() == .OK, let url = p.url {
                        model.setRoutes(routes + [AudioRoute(file: url.path, output: nextOutput())], on: machine)
                    }
                }
            }
        }
        .fixedSize()
    }

    /// Set per Mac, so only this Mac's own interface can be chosen from here.
    private var devicePicker: some View {
        Picker("Interface", selection: $sound.chosenDevice) {
            Text("Automatic" + (model.soundDevice.map { ": \($0.name)" } ?? "")).tag(String?.none)
            // A chosen interface that's been unplugged stays visible, marked. A
            // Picker whose selection matches no tag draws blank, which hides the
            // fact that sound has moved to another device.
            if let c = sound.chosenDevice, !c.isEmpty, !sound.devices.contains(where: { $0.uid == c }) {
                Text("\(c) (not connected)").tag(String?.some(c))
            }
            ForEach(sound.devices, id: \.uid) { d in
                Text("\(d.name) (\(d.outputs) output\(d.outputs == 1 ? "" : "s"))").tag(String?.some(d.uid))
            }
        }
        .fixedSize()
    }
}
