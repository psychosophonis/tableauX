import Foundation

/// One panel's settings. Panel n plays on display n (see DisplayOrder).
public struct PanelConfig: Codable, Equatable {
    public var file: String?          // absolute path; nil = this display stays black
    public var audio: Bool
    public var scaling: Scaling

    public init(file: String? = nil, audio: Bool = false, scaling: Scaling = .fit) {
        self.file = file; self.audio = audio; self.scaling = scaling
    }
}

/// [claude] One Mac's part of a show: its displays' panels, numbered on that
/// Mac left to right (docs/architecture.md § Show file, v3 § Show and media).
///
/// The name is the Mac's computer name, the one a person sees and can change
/// in System Settings. It is an IDENTIFIER CHOSEN FOR PEOPLE, not machines: a
/// hardware ID would never collide, but nobody could read a show file or fix
/// one by hand, and a replacement Mac could never take over a part. The cost
/// is that two Macs with the same name would claim the same part.
public struct Machine: Codable, Equatable {
    public var name: String
    public var panels: [PanelConfig]

    public init(name: String, panels: [PanelConfig] = []) {
        self.name = name; self.panels = panels
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

/// A saved arrangement: which file goes on which display of which Mac, and how.
public struct Show: Codable, Equatable {
    public static let currentVersion = 2
    public var version: Int
    public var machines: [Machine]
    public var sync: SyncSettings
    public var playOnLaunch: Bool

    public init(machines: [Machine], sync: SyncSettings = .standard, playOnLaunch: Bool = false) {
        self.version = Show.currentVersion; self.machines = machines
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
public enum ShowFile {
    public static func decode(_ data: Data) throws -> Show {
        // Check the version BEFORE decoding the rest: a file of another version
        // may not even have this version's fields, and "missing key: machines"
        // would hide the real reason it can't be read.
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard version == Show.currentVersion else { throw ShowFileError.unsupportedVersion(version) }
        let show = try JSONDecoder().decode(Show.self, from: data)
        // VALIDATE AT THE BOUNDARY: everything past this point may assume a
        // show has a machine and sane sync numbers, so nothing downstream needs
        // to re-check a hand-edited file.
        guard !show.machines.isEmpty else { throw ShowFileError.noMachines }
        guard show.sync.tolerance >= 1, show.sync.grace >= 0 else { throw ShowFileError.invalidSync(show.sync) }
        return show
    }

    public static func encode(_ show: Show) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]   // readable and diffable by hand
        return try e.encode(show)
    }
}
