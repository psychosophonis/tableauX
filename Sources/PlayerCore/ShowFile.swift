import Foundation

/// One panel's settings. Panel n plays on display n (see DisplayOrder).
public struct PanelConfig: Codable, Equatable {
    /// [claude] v4: relative to this Mac's media folder ("Smith/1.mp4"), or an
    /// absolute path ("/…") for a v2 show or a file chosen from elsewhere.
    /// nil = this display stays black.
    public var file: String?
    public var audio: Bool
    public var scaling: Scaling

    public init(file: String? = nil, audio: Bool = false, scaling: Scaling = .fit) {
        self.file = file; self.audio = audio; self.scaling = scaling
    }
}

/// [claude] One Mac in a show (docs/architecture.md § v4 › Model). Its panels
/// are per work now (`Work.screens[name]`); the machine itself only says who
/// it is and how many displays it has, which numbers the screens across Macs.
///
/// The name is the Mac's computer name, the one a person sees and can change
/// in System Settings. It is an IDENTIFIER CHOSEN FOR PEOPLE, not machines: a
/// hardware ID would never collide, but nobody could read a show file or fix
/// one by hand, and a replacement Mac could never take over a part. The cost
/// is that two Macs with the same name would claim the same part.
public struct Machine: Codable, Equatable {
    public var name: String
    public var displays: Int

    public init(name: String, displays: Int = 0) {
        self.name = name; self.displays = displays
    }
}

/// [claude] How closely the show holds its panels to the shared clock
/// (docs/architecture.md § Sync › Drift check).
///
/// Two numbers, because they answer different questions. `tolerance` is how
/// far is too far (in frames, so it means the same thing at any frame rate);
/// `grace` is how long a panel may stay too far before it is corrected. A
/// correction is a seek, which is itself a visible jump, so for most works
/// it is better to tolerate a few frames, and a brief blip, than to jump.
public struct SyncSettings: Codable, Equatable {
    public var tolerance: Int         // frames, ≥ 1
    public var grace: Double          // seconds, ≥ 0

    /// Mat's defaults (2026-10-21): 3 frames (100 ms at 30 fps), 5 s.
    public static let standard = SyncSettings(tolerance: 3, grace: 5)

    public init(tolerance: Int, grace: Double) {
        self.tolerance = tolerance; self.grace = grace
    }
}

/// A saved arrangement: the Macs, and a playlist of works, each saying which
/// file goes on which display of which Mac, and how.
public struct Show: Codable, Equatable {
    public static let currentVersion = 3
    public var version: Int
    public var machines: [Machine]
    public var works: [Work]                  // [claude] v4: playlist order
    public var playlist: PlaylistSettings
    public var sync: SyncSettings
    public var playOnLaunch: Bool

    public init(machines: [Machine], works: [Work] = [], playlist: PlaylistSettings = .standard,
                sync: SyncSettings = .standard, playOnLaunch: Bool = false) {
        self.version = Show.currentVersion; self.machines = machines
        self.works = works; self.playlist = playlist
        self.sync = sync; self.playOnLaunch = playOnLaunch
    }

    /// [claude] Which machine entry this Mac plays (§ Show file › which machine):
    /// the one with its name; failing that, the only one, so a show made on
    /// another Mac still opens and plays; failing that, none.
    ///
    /// The fallback is what keeps a one-Mac show PORTABLE: copy it to the lab
    /// machine and it plays, even though it was saved under a laptop's name.
    /// With several machines there is no safe guess, so nil, and setup says so.
    public func machineIndex(named name: String) -> Int? {
        if let i = machines.firstIndex(where: { $0.name == name }) { return i }
        return machines.count == 1 ? 0 : nil
    }
}

public enum ShowFileError: Error, Equatable {
    case unsupportedVersion(Int)
    case noMachines
    case invalidSync(SyncSettings)
    case invalidGap(Double)
}

/// [claude] A version 2 show, kept only to be read and converted.
///
/// This is the usual way to MIGRATE a file format: decode the old shape into
/// its own type, exactly as it was written, then convert that to the current
/// model in one function. The current model never has to carry old fields,
/// and each conversion can be tested on its own.
private struct ShowV2: Decodable {
    struct MachineV2: Decodable { let name: String; let panels: [PanelConfig] }
    let machines: [MachineV2]
    let sync: SyncSettings
    let playOnLaunch: Bool

    /// One work that plays the way every show did before playlists: until
    /// stopped, each panel looping on its own length.
    var converted: Show {
        let work = Work(name: "Show", screens: Dictionary(machines.map { ($0.name, $0.panels) }, uniquingKeysWith: { a, _ in a }),
                        repeat: .untilNext, shorter: .loop)
        return Show(machines: machines.map { Machine(name: $0.name, displays: $0.panels.count) },
                    works: [work], sync: sync, playOnLaunch: playOnLaunch)
    }
}

/// Reading and writing show files (`.tableaux`, formerly `.msshow`; JSON).
///
/// The file carries a VERSION NUMBER from day one. A show saved by a later
/// version of the app may mean something this version doesn't understand, and
/// silently half-reading it would be worse than refusing. The version lets a
/// reader tell "a file I understand" from "a file I don't" before it trusts any
/// of the contents. Adding the number later would be too late, because the
/// files already out there wouldn't have it.
///
/// [claude] Version 2 (machines, sync) replaced version 1 without a converter:
/// no real shows existed yet (Mat, 2026-10-21). A version 1 file is refused
/// like any other unknown version, which is the rule doing its job.
/// Version 3 (playlists, § v4) does convert version 2, because § v4 › Model
/// says a version 2 show opens as one work: shows saved with 0.1.x builds
/// (the lab run, the two-MacBook run) keep working.
public enum ShowFile {
    public static func decode(_ data: Data) throws -> Show {
        // Check the version BEFORE decoding the rest: a file of another version
        // may not even have this version's fields, and "missing key: machines"
        // would hide the real reason it can't be read.
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        let show: Show
        switch version {
        case Show.currentVersion: show = try JSONDecoder().decode(Show.self, from: data)
        case 2: show = try JSONDecoder().decode(ShowV2.self, from: data).converted
        default: throw ShowFileError.unsupportedVersion(version)
        }
        // VALIDATE AT THE BOUNDARY: everything past this point may assume a
        // show has a machine and sane numbers, so nothing downstream needs to
        // re-check a hand-edited file.
        guard !show.machines.isEmpty else { throw ShowFileError.noMachines }
        guard show.sync.tolerance >= 1, show.sync.grace >= 0 else { throw ShowFileError.invalidSync(show.sync) }
        guard show.playlist.gap >= 0 else { throw ShowFileError.invalidGap(show.playlist.gap) }
        return show
    }

    public static func encode(_ show: Show) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]   // readable and diffable by hand
        return try e.encode(show)
    }
}
