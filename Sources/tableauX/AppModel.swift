import AppKit
import AVFoundation
import PlayerCore
import SystemConfiguration
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
    @Published var show = Show(machines: [Machine(name: AppModel.thisMac)])
    @Published private(set) var media: [String: MediaInfo] = [:]     // keyed by file path
    @Published private(set) var unreadable: Set<String> = []
    @Published private(set) var showPath: URL?
    @Published private(set) var isPlaying = false
    @Published var lastError: String?

    /// [claude] This Mac's computer name, which picks its part of the show
    /// (§ Show file › which machine). Read through SystemConfiguration rather
    /// than `Host.current().localizedName`, which can stall on a network name
    /// lookup; this is the name set in System Settings, read locally.
    static let thisMac = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName

    /// Which of the show's machines this Mac plays; nil = the show has no part for it.
    var machineIndex: Int? { show.machineIndex(named: Self.thisMac) }

    /// This Mac's panels, in display order. Empty when the show has no part for it.
    var panels: [PanelConfig] { machineIndex.map { show.machines[$0].panels } ?? [] }

    private var playback: Playback?
    private let lastShowKey = "lastShowPath"
    private var hasLaunched = false

    // MARK: Network mode (v3) [claude]

    /// v3 § One app, three modes. Stored per Mac, not in the show: it says what
    /// this machine is, and the same show can be opened in any mode.
    enum Mode: String, CaseIterable, Identifiable {
        case standalone, conductor, player
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @Published var mode: Mode = .standalone {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
            if clockReady { restartClock() }
        }
    }
    /// False until init has restored the saved mode. Without it, restoring the
    /// mode in init started the clock once from `didSet` and again from init's
    /// own call (observed 2026-10-21: the second bind found the port taken).
    private var clockReady = false
    /// The conductor's address, as typed. Applied by `restartClock()` (setup
    /// calls it when the field is submitted), not on every keystroke.
    @Published var conductorAddress = "" {
        didSet { UserDefaults.standard.set(conductorAddress, forKey: addressKey) }
    }
    /// One line about the clock for setup (§ v3 › Clock, What setup shows).
    @Published private(set) var clockStatus = ""

    private let modeKey = "networkMode", addressKey = "conductorAddress"
    private var server: ClockServer?
    private var client: ClockClient?
    private var statusTimer: Timer?
    private var statusTicks = 0

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
        // Restore the saved mode, then start the clock exactly once.
        conductorAddress = UserDefaults.standard.string(forKey: addressKey) ?? ""
        mode = UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init) ?? .standalone
        clockReady = true
        restartClock()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClockStatus() }
        }
    }

    /// Stops whatever clock component is running and starts the one the mode
    /// asks for. One place that owns the transition, so there is never a
    /// server and a client at once, or a socket left open from the last mode.
    func restartClock() {
        server?.stop(); server = nil
        client?.stop(); client = nil
        do {
            switch mode {
            case .standalone: break
            case .conductor: server = try ClockServer()
            case .player:
                let address = conductorAddress.trimmingCharacters(in: .whitespaces)
                if !address.isEmpty { client = try ClockClient(conductor: address) }
            }
        } catch {
            clockStatus = "Clock: \(error)"
            NSLog("clock: %@", "\(error)")
            return
        }
        NSLog("clock: mode %@", mode.rawValue)
        updateClockStatus()
    }

    /// Once a second: refresh the status line; every 10 s, also log it, so a
    /// long run can be read back afterwards with `log show`.
    private func updateClockStatus() {
        statusTicks += 1
        if let server {
            let players = server.players()
            clockStatus = "Conductor: answering clock requests on \(server.addresses.joined(separator: ", "))"
                + (players.isEmpty ? ". No players yet." : ". Players: \(players.joined(separator: ", ")).")
        } else if let client {
            clockStatus = Self.describe(client.status)
        } else if mode == .player {
            clockStatus = "Player: type the conductor's address and press Return."
        } else if clockStatus.hasPrefix("Clock:") == false {
            clockStatus = ""
        }
        if statusTicks % 10 == 0, !clockStatus.isEmpty { NSLog("clock: %@", clockStatus) }
    }

    /// e.g. "Player of 10.0.0.5: 20 replies/s · steady to 0.28 ms · drift −12.0 ppm · offset 765898979.83 ms".
    /// The thresholds are the targets: no reply in 5 s is T10 failing, a
    /// spread over 5 ms is T11 failing.
    private static func describe(_ s: ClockClient.Status) -> String {
        let head = "Player of \(s.conductor)"
        guard let since = s.secondsSinceReply else {
            return s.secondsRunning > 5
                ? "\(head): no replies. Check the address, that the conductor is running, and that this network lets Macs reach each other."
                : "\(head): asking…"
        }
        if since > 5 { return String(format: "%@: no replies for %.0f s; running on the last estimate.", head, since) }
        var parts = [String(format: "%.0f replies/s", s.repliesPerSecond)]
        if let st = s.steadiness {
            parts.append(String(format: "steady to %.2f ms%@", st * 1000, st > 0.005 ? " (over 5 ms)" : ""))
        } else {
            parts.append("measuring steadiness…")
        }
        if let d = s.drift { parts.append(String(format: "drift %.1f ppm", d * 1e6)) }
        // In ms, as the probe prints it, so the two can be compared directly.
        if let o = s.offset { parts.append(String(format: "offset %.2f ms", o * 1000)) }
        return "\(head): " + parts.joined(separator: " · ")
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
        guard let mi = machineIndex else { return }
        while show.machines[mi].panels.count < displays.count { show.machines[mi].panels.append(PanelConfig()) }
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
        guard p.runModal() == .OK, let url = p.url, let mi = machineIndex else { return }
        show.machines[mi].panels[i].file = url.path
        loadInfo(url.path)
    }

    func clear(panel i: Int) {
        if let mi = machineIndex { show.machines[mi].panels[i].file = nil }
    }

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
        if machineIndex == nil {
            let names = show.machines.map(\.name).joined(separator: ", ")
            return (["This show has parts for \(names), but not for this Mac (\(Self.thisMac))."], [])
        }
        let active = Array(panels.prefix(displays.count).enumerated())
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
        if panels.count > displays.count {
            warnings.append("This show has \(panels.count) panels but \(displays.count) display(s) are connected. The extra panels won't play.")
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
            // Only this Mac's files: the other machines' paths are on their disks.
            panels.compactMap(\.file).filter(fileExists).forEach(loadInfo)
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
              panels.prefix(displays.count).map { $0.file.map { ($0 as NSString).lastPathComponent } ?? "-" }.joined(separator: ", "))
        if isPlaying { NSLog("Play refused: already playing"); return }
        let blocking = problems.blocking
        if !blocking.isEmpty { NSLog("Play refused: %@", blocking.joined(separator: " | ")); return }
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { s in
            Self.info(for: s).map { ($0.id, s) }
        })
        let assignments = zip(displays, panels).compactMap { d, p in screens[d.id].map { ($0, p) } }
        lastError = nil
        // The setup window is hidden only once the panel windows are up, never
        // before: hiding the last visible window quits the app (see Playback.init).
        let pb = Playback(assignments: assignments, sync: show.sync,
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
