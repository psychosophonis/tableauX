import PlayerCore
import SwiftUI

// [claude] Interface step 1: one line for the state of things, instead of a
// growing column of red and orange sentences. Role and players, displays,
// then problems: the first thing stopping Present in red (click for all),
// otherwise a count of notes, otherwise "Ready". Details stay one click
// away; the line itself never grows.

struct StatusLine: View {
    @ObservedObject var model: AppModel
    @State private var showingAll = false

    var body: some View {
        let p = model.problems
        let blocking = p.blocking + (model.lastError.map { [$0] } ?? [])
        HStack(spacing: 12) {
            Circle().fill(blocking.isEmpty ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(role).help(model.clockStatus)
            Text(displaysText).foregroundStyle(.secondary)
            if let note = model.libraryNote {
                Text(note).foregroundStyle(.secondary).lineLimit(1)
                Button("OK") { model.libraryNote = nil }.controlSize(.small)
            }
            Spacer()
            Button {
                showingAll = true
            } label: {
                if let first = blocking.first {
                    Text(blocking.count > 1 ? "\(first)  (+\(blocking.count - 1) more)" : first)
                        .foregroundStyle(.red).lineLimit(1)
                } else if !p.warnings.isEmpty {
                    Text("⚠︎ \(p.warnings.count) note\(p.warnings.count == 1 ? "" : "s")").foregroundStyle(.orange)
                } else {
                    Text("Ready").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(blocking.isEmpty && p.warnings.isEmpty)
            .popover(isPresented: $showingAll, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(blocking, id: \.self) { Text($0).foregroundStyle(.red) }
                    ForEach(p.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
                .padding()
                .frame(width: 460, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private var role: String {
        switch model.mode {
        case .standalone: return "Standalone"
        case .conductor:
            let lines = model.playerLines
            return lines.isEmpty ? "Conductor · no players connected" : "Conductor · " + lines.joined(separator: " · ")
        case .player:
            if let lengths = model.sharedLengths { return "Player · conductor's show, \(lengths.count) work\(lengths.count == 1 ? "" : "s")" }
            return model.linkUp ? "Player · waiting for the conductor's show" : "Player · looking for the conductor"
        }
    }

    private var displaysText: String {
        let have = model.displays.count, design = model.designDisplays
        return have < design ? "this Mac: \(have) of \(design) displays connected" : "this Mac: \(have) display\(have == 1 ? "" : "s")"
    }
}
