import AppKit
import AVFoundation
import PlayerCore
import UniformTypeIdentifiers

/// What setup needs to show about a chosen file.
struct MediaInfo: Equatable {
    var size: CGSize
    var duration: Double
    var fps: Double
    var hasAudio: Bool
}

/// The app's state: connected displays, the show being edited, and facts about
/// each chosen file. SwiftUI redraws the setup window whenever a @Published
/// property changes. That's the OBSERVER PATTERN: the view subscribes to the
/// model instead of the model telling the view what to redraw.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var show = Show(panels: [])
    @Published private(set) var media: [String: MediaInfo] = [:]     // keyed by file path
    @Published private(set) var unreadable: Set<String> = []
    @Published private(set) var showPath: URL?
    @Published private(set) var isPlaying = false
    @Published var lastError: String?

    private var playback: Playback?
    private let lastShowKey = "lastShowPath"
    private var hasLaunched = false

    init() {
        refreshDisplays()
        // Re-read displays whenever one is plugged in, unplugged or rearranged.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        if let path = UserDefaults.standard.string(forKey: lastShowKey) {
            open(URL(fileURLWithPath: path))
        }
    }

    /// Called once the setup window is on screen; starts "Play on launch".
    ///
    /// [claude] This used to happen in init, which runs before SwiftUI has made
    /// the setup window. play() hides the setup windows it can find, and at that
    /// moment there were none, so the setup window appeared afterwards, became
    /// the key window behind the playback windows, and took Space and Esc. The
    /// fix is about ORDER OF INITIALISATION: act on the window only once it
    /// exists. The flag makes it a ONE-SHOT, because SwiftUI may call onAppear
    /// again when the window is shown after playback, and that must not restart
    /// the show.
    func launched() {
        guard !hasLaunched else { return }
        hasLaunched = true
        if show.playOnLaunch { play() }
    }

    // MARK: Displays

    private func refreshDisplays() {
        displays = DisplayOrder.sorted(NSScreen.screens.compactMap(Self.info(for:)))
        // One panel per display. Extra panels from a show made on a bigger array
        // are kept (not deleted) so saving on this machine doesn't lose them.
        while show.panels.count < displays.count { show.panels.append(PanelConfig()) }
    }

    private func screensChanged() {
        // A display vanishing mid-show would leave a panel playing nowhere and the
        // others out of their arrangement, so stop and let a person look.
        //
        // [claude] But only if the displays REALLY changed. macOS posts this
        // notification for things that aren't display changes at all, and
        // Playback causes one itself: hiding the Dock and menu bar for the show
        // posts it, so the show used to stop itself a moment after starting
        // (confirmed by logging the display list before and after: identical).
        // Comparing the canonical sorted list (id, name, position, pixel size)
        // turns a noisy EVENT into a real STATE CHANGE before acting on it.
        let now = DisplayOrder.sorted(NSScreen.screens.compactMap(Self.info(for:)))
        guard now != displays else { return }
        if isPlaying {
            NSLog("Displays changed during playback (%d -> %d); stopping", displays.count, now.count)
            stop()
            lastError = "Displays changed during playback, so playback stopped."
        }
        refreshDisplays()
    }

    static func info(for screen: NSScreen) -> DisplayInfo? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(n.uint32Value)
        // The display MODE has the real pixel count. NSScreen.frame is in points,
        // which on a HiDPI ("looks like 1920 × 1080") 4K screen is half the pixels.
        let mode = CGDisplayCopyDisplayMode(id)
        let pixels = CGSize(width: mode?.pixelWidth ?? Int(screen.frame.width),
                            height: mode?.pixelHeight ?? Int(screen.frame.height))
        return DisplayInfo(id: id, name: screen.localizedName, frame: screen.frame, pixelSize: pixels)
    }

    // MARK: Panels

    func choose(panel i: Int) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie]
        guard p.runModal() == .OK, let url = p.url else { return }
        show.panels[i].file = url.path
        loadInfo(url.path)
    }

    func clear(panel i: Int) { show.panels[i].file = nil }

    private func loadInfo(_ path: String) {
        guard media[path] == nil else { return }
        Task {
            do {
                media[path] = try await Self.readInfo(URL(fileURLWithPath: path))
                unreadable.remove(path)
            } catch {
                unreadable.insert(path)
            }
        }
    }

    static func readInfo(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let v = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (natural, transform, fps) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        // Phone video is often stored sideways with a rotation flag; apply it so
        // an upright clip reports as upright (1080 × 1920, not 1920 × 1080).
        let shown = natural.applying(transform)
        let audio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        return MediaInfo(size: CGSize(width: abs(shown.width), height: abs(shown.height)),
                         duration: duration, fps: Double(fps), hasAudio: audio)
    }

    func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Problems that block playback (missing or unreadable files) or deserve a
    /// warning (lengths that differ, so panels will drift in phase).
    var problems: (blocking: [String], warnings: [String]) {
        var blocking: [String] = [], warnings: [String] = []
        let active = Array(show.panels.prefix(displays.count).enumerated())
        for (i, p) in active {
            guard let f = p.file else { continue }
            if !fileExists(f) { blocking.append("Panel \(i + 1): file not found (\(f)).") }
            else if unreadable.contains(f) { blocking.append("Panel \(i + 1): can't read this file as video.") }
        }
        if !active.contains(where: { $0.element.file != nil }) { blocking.append("Choose a file for at least one panel.") }
        let lengths = active.compactMap { $0.element.file.flatMap { media[$0] } }
        if let lo = lengths.map(\.duration).min(), let hi = lengths.map(\.duration).max(),
           hi - lo > 1 / (lengths.map(\.fps).max() ?? 30) {
            warnings.append(String(format: "Lengths differ (%.2f s to %.2f s). Each panel loops on its own length, so they'll drift apart in phase.", lo, hi))
        }
        if show.panels.count > displays.count {
            warnings.append("This show has \(show.panels.count) panels but \(displays.count) display(s) are connected. The extra panels won't play.")
        }
        return (blocking, warnings)
    }

    // MARK: Show files

    /// Show files are `.tableaux`. Open also accepts `.msshow`, the extension
    /// from before the app was renamed: the contents are the same format (the
    /// version number inside is what ShowFile checks), so only the name moved.
    static let showExtension = "tableaux"
    static let legacyShowExtension = "msshow"

    func openDialog() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [Self.showExtension, Self.legacyShowExtension]
            .compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK, let url = p.url { open(url) }
    }

    func open(_ url: URL) {
        do {
            show = try ShowFile.decode(Data(contentsOf: url))
            showPath = url
            UserDefaults.standard.set(url.path, forKey: lastShowKey)
            refreshDisplays()
            show.panels.compactMap(\.file).filter(fileExists).forEach(loadInfo)
        } catch {
            lastError = "Couldn't open \(url.lastPathComponent): \(error)"
        }
    }

    func saveDialog() {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: Self.showExtension) ?? .json]
        // Saving an old .msshow offers the same name with the new extension.
        let base = showPath?.deletingPathExtension().lastPathComponent ?? "Untitled"
        p.nameFieldStringValue = "\(base).\(Self.showExtension)"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try ShowFile.encode(show).write(to: url)
            showPath = url
            UserDefaults.standard.set(url.path, forKey: lastShowKey)
        } catch {
            lastError = "Couldn't save: \(error)"
        }
    }

    // MARK: Playback

    func play() {
        // [claude] Say why a Play does nothing. Before this, a refused Play was
        // a silent return, which is exactly what "nothing happened" looks like.
        NSLog("Play pressed: %d display(s), files: %@", displays.count,
              show.panels.prefix(displays.count).map { $0.file.map { ($0 as NSString).lastPathComponent } ?? "-" }.joined(separator: ", "))
        if isPlaying { NSLog("Play refused: already playing"); return }
        let blocking = problems.blocking
        if !blocking.isEmpty { NSLog("Play refused: %@", blocking.joined(separator: " | ")); return }
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { s in
            Self.info(for: s).map { ($0.id, s) }
        })
        let assignments = zip(displays, show.panels).compactMap { d, p in screens[d.id].map { ($0, p) } }
        lastError = nil
        // The setup window is hidden only once the panel windows are up, never
        // before: hiding the last visible window quits the app (see Playback.init).
        let pb = Playback(assignments: assignments,
                          onWindowsUp: { [weak self] in self?.setupWindows.forEach { $0.orderOut(nil) } },
                          onEnd: { [weak self] in self?.playbackEnded() })
        playback = pb
        isPlaying = true
        Task {
            do { try await pb.start() }
            catch {
                pb.stop()
                lastError = "Couldn't start playback: \(error)"
                NSLog("%@", lastError ?? "")
            }
        }
    }

    func stop() { playback?.stop() }

    static let setupTitle = "tableauX"
    private var setupWindows: [NSWindow] {
        NSApp.windows.filter { !($0 is PanelWindow) && $0.title == Self.setupTitle }
    }

    private func playbackEnded() {
        playback = nil
        isPlaying = false
        setupWindows.forEach { $0.makeKeyAndOrderFront(nil) }
    }
}
