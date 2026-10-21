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

/// A saved arrangement: which file goes on which display, and how.
public struct Show: Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var panels: [PanelConfig]
    public var playOnLaunch: Bool

    public init(panels: [PanelConfig], playOnLaunch: Bool = false) {
        self.version = Show.currentVersion; self.panels = panels; self.playOnLaunch = playOnLaunch
    }
}

public enum ShowFileError: Error, Equatable {
    case unsupportedVersion(Int)
}

/// Reading and writing show files (`.tableaux`, formerly `.msshow`; JSON).
///
/// The file carries a VERSION NUMBER from day one. A show saved by a later
/// version of the app may mean something this version doesn't understand, and
/// silently half-reading it would be worse than refusing. The version lets a
/// reader tell "a file I understand" from "a file I don't" before it trusts any
/// of the contents. Adding the number later would be too late, because the
/// files already out there wouldn't have it.
public enum ShowFile {
    public static func decode(_ data: Data) throws -> Show {
        let show = try JSONDecoder().decode(Show.self, from: data)
        guard show.version == Show.currentVersion else { throw ShowFileError.unsupportedVersion(show.version) }
        return show
    }

    public static func encode(_ show: Show) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]   // readable and diffable by hand
        return try e.encode(show)
    }
}
