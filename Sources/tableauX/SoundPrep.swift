import CoreAudio
import CryptoKit
import Foundation
import PlayerCore

// [claude] v5: getting a work's sound ready on this Mac (docs/architecture.md
// § The bake, § Output device). AudioRouting decides and AudioBake reads and
// writes; this class keeps track of what has been measured and baked, and does
// that work in the background, one job at a time.

/// What one work needs from one Mac.
struct SoundRequest {
    var work: String
    var machine: String
    var routes: [AudioRoute]
    /// Full path of each route's source. nil = a screen with no file on it.
    var paths: [String?]
    var looping: Bool
    var minimumLength: Double
    /// False for another Mac's routes: measure what's here, bake nothing.
    var bakeHere: Bool
}

enum SoundStatus: Equatable {
    case none, reading, baking, ready
    case failed(String)
}

struct SoundState {
    var plan: AudioRouting.Plan
    var status: SoundStatus
    var file: URL
}

@MainActor
final class SoundPrep: ObservableObject {
    @Published private(set) var facts: [String: AudioFacts] = [:]     // by full path
    @Published private(set) var unreadable: [String: String] = [:]
    @Published private(set) var devices: [AudioOutputs.Device] = []
    @Published private(set) var defaultDevice: String?
    /// The device chosen by hand, or nil for automatic. Per Mac, like the mode:
    /// the show travels between Macs, the interface doesn't.
    @Published var chosenDevice: String? = UserDefaults.standard.string(forKey: SoundPrep.deviceKey) {
        didSet { UserDefaults.standard.set(chosenDevice, forKey: Self.deviceKey) }
    }
    private static let deviceKey = "soundDevice"

    /// Called when a job finishes, so the model can recheck what blocks Present.
    var onChange: (() -> Void)?

    private var stamps: [String: String] = [:]           // path → size and date, read at the last refresh
    private var failures: [String: String] = [:]         // bake name → why
    private var measuring: Set<String> = []              // measures queued or running
    private var queue: [Job] = []
    private var running = false

    private enum Job {
        case measure(String)
        case bake(name: String, plan: AudioRouting.Plan, sources: [URL], to: URL, minimumLength: Double, looping: Bool)
    }

    /// `~/Library/Caches`, because a bake is DERIVED DATA: it can always be made
    /// again from the sources. Caches is where macOS expects such files, and may
    /// empty it under disk pressure; the only cost is baking again.
    static let folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tableauX/sound", isDirectory: true)

    // MARK: Asking

    /// What a work's sound amounts to right now.
    ///
    /// COMMAND-QUERY SEPARATION: asking (`state`) changes nothing and doing
    /// (`refresh`) answers nothing. SwiftUI redraws whenever it likes, so a query
    /// that started a bake would start work at unpredictable moments.
    ///
    /// The status is DERIVED, not stored: there's no state machine holding "baking"
    /// or "ready", only the facts, the failures and whether the file exists. A stored
    /// status can disagree with reality (the cache is emptied, a source is replaced);
    /// one worked out on demand can't, which removes a whole class of stale-state bug.
    func state(_ r: SoundRequest) -> SoundState {
        var sourceFacts: [AudioFacts?] = []
        var missing: [String] = []
        for (i, path) in r.paths.enumerated() {
            guard let path else {
                sourceFacts.append(AudioFacts(channels: 0))     // a screen left black has no sound to send
                continue
            }
            if let why = unreadable[path] {
                missing.append("\(AudioRouting.name(r.routes[i])): \(why)")
                sourceFacts.append(nil)
            } else if r.bakeHere, !FileManager.default.fileExists(atPath: path) {
                missing.append("\(AudioRouting.name(r.routes[i])): file not found (\(path)).")
                sourceFacts.append(nil)
            } else {
                sourceFacts.append(facts[path])
            }
        }
        var plan = AudioRouting.plan(routes: r.routes, facts: sourceFacts)
        plan.problems += missing
        let file = Self.folder.appendingPathComponent(name(of: r))
        let status: SoundStatus
        if plan.incomplete { status = missing.isEmpty ? .reading : .none }
        else if !plan.problems.isEmpty || plan.feeds.isEmpty { status = .none }
        else if let why = failures[file.lastPathComponent] { status = .failed(why) }
        else { status = FileManager.default.fileExists(atPath: file.path) ? .ready : .baking }
        return SoundState(plan: plan, status: status, file: file)
    }

    /// The bake's name: a CONTENT-ADDRESSED cache key, a hash of everything that
    /// decides its contents. Changing a route or replacing a source changes the
    /// name, so a stale bake can't be played; nothing has to remember to clear it.
    /// The first half names the work and Mac, which lets a finished bake delete
    /// the older versions of itself.
    private func name(of r: SoundRequest) -> String {
        var key = ""
        for (route, path) in zip(r.routes, r.paths) {
            key += "\(route.output)|\(route.take.rawValue)|\(path ?? "-")|\(path.flatMap { stamps[$0] } ?? "")\n"
        }
        key += "\(r.looping)|" + (r.looping ? String(format: "%.3f", r.minimumLength) : "")
        return "\(Self.hash(r.machine + "/" + r.work))-\(Self.hash(key)).wav"
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Doing

    /// Reads file stamps, then queues whatever is missing. Called about once a
    /// second, and cheap when there's nothing to do.
    ///
    /// A RECONCILIATION LOOP: compare what should exist with what does, and close
    /// the difference. The same pattern as a player following the conductor's state
    /// (§ v3 › Show state). It needs no event for each thing that could change (a
    /// file dropped in the folder, a route edited, the cache emptied), since the next
    /// pass notices all of them, and macOS gives no simple single event for those.
    func refresh(_ requests: [SoundRequest]) {
        for path in requests.flatMap({ $0.paths.compactMap { $0 } }) { want(path) }
        for r in requests where r.bakeHere {
            let s = state(r)
            guard s.status == .baking, !isQueued(s.file.lastPathComponent) else { continue }
            let sources = r.paths.map { URL(fileURLWithPath: $0 ?? "/dev/null") }
            queue.append(.bake(name: s.file.lastPathComponent, plan: s.plan, sources: sources, to: s.file,
                               minimumLength: r.minimumLength, looping: r.looping))
        }
        runNext()
    }

    /// Makes sure a file on this Mac gets measured, and measured again if it changes.
    func want(_ path: String) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return }
        let stamp = "\((a[.size] as? Int64) ?? 0)/\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if stamps[path] != stamp {
            stamps[path] = stamp
            facts[path] = nil
            unreadable[path] = nil
        }
        guard facts[path] == nil, unreadable[path] == nil, measuring.insert(path).inserted else { return }
        queue.insert(.measure(path), at: 0)      // measuring is quick, and a bake may be waiting on it
        runNext()
    }

    private func isQueued(_ name: String) -> Bool {
        queue.contains { if case .bake(let n, _, _, _, _, _) = $0 { return n == name } else { return false } }
            || bakingNow == name
    }
    private var bakingNow: String?

    /// A SERIAL WORK QUEUE: one job at a time. A bake reads every source start to
    /// finish, and two at once would compete for the same disk for no gain.
    ///
    /// The Task inherits the main actor, so this bookkeeping stays on one thread and
    /// needs no locks. The heavy work still runs elsewhere, because `AudioBake`'s
    /// functions are nonisolated `async`: awaiting them hops off the main actor and
    /// back again, which keeps the window responsive during a long bake.
    private func runNext() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let job = queue.removeFirst()
        Task {
            switch job {
            case .measure(let path):
                do {
                    facts[path] = try await AudioBake.analyse(URL(fileURLWithPath: path))
                } catch {
                    unreadable[path] = "can't read this file as sound."
                    NSLog("sound: can't read %@: %@", path, error.localizedDescription)
                }
                measuring.remove(path)
            case .bake(let name, let plan, let sources, let to, let minimumLength, let looping):
                bakingNow = name
                let t0 = Date()
                do {
                    try await AudioBake.bake(plan: plan, sources: sources, to: to, minimumLength: minimumLength, looping: looping)
                    Self.deleteOlderVersions(of: name)
                    NSLog("sound: baked %d outputs in %.1f s: %@", plan.outputs, Date().timeIntervalSince(t0), name)
                } catch {
                    failures[name] = error.localizedDescription
                    NSLog("sound: bake failed: %@", error.localizedDescription)
                }
                bakingNow = nil
            }
            running = false
            onChange?()
            runNext()
        }
    }

    private nonisolated static func deleteOlderVersions(of name: String) {
        let fm = FileManager.default
        guard let prefix = name.split(separator: "-").first,
              let all = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for f in all where f.hasPrefix(prefix + "-") && f != name {
            try? fm.removeItem(at: folder.appendingPathComponent(f))
        }
    }

    // MARK: Listing a work's audio folder

    /// A work's `audio/` folder, one level of per-Mac subfolders down, each name
    /// relative to it ("a_1.wav", "Gallery 2/b.wav"), as AudioScan expects.
    nonisolated static func listing(workFolder: String) -> [String] {
        let fm = FileManager.default
        let root = (workFolder as NSString).appendingPathComponent(AudioScan.folderName)
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out = AudioScan.sounds(names)
        for name in names where !name.hasPrefix(".") {
            let path = (root as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  let inner = try? fm.contentsOfDirectory(atPath: path) else { continue }
            out += AudioScan.sounds(inner).map { "\(name)/\($0)" }
        }
        return out
    }

    // MARK: Devices

    func refreshDevices() {
        let found = Self.outputDevices()
        if found != devices { devices = found }
        let def = Self.defaultOutput()
        if def != defaultDevice { defaultDevice = def }
    }

    func device(needed: Int) -> AudioOutputs.Device? {
        AudioOutputs.pick(devices: devices, chosen: chosenDevice, defaultUID: defaultDevice, needed: needed)
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Core Audio describes everything as PROPERTIES of objects, fetched through one
    /// C function. A string comes back as a CFString that we now own, under Core
    /// Foundation's "CREATE RULE": whoever is handed it must release it. Swift can't
    /// know that from a C signature, so `Unmanaged` holds it and `takeRetainedValue`
    /// says "this is already retained, take over the release". Get that wrong one way
    /// and it leaks on every read; the other way and it crashes.
    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func defaultOutput() -> String? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    /// Every device with outputs. A device's channels are spread over its output
    /// streams, so they're counted across all of them.
    ///
    /// AudioBufferList is a C VARIABLE-LENGTH STRUCT: its declared type holds one
    /// buffer, but the real one runs on past the end of the struct, as many as the
    /// device has. So it can't be an ordinary Swift value. Core Audio is asked for
    /// the size first, raw memory of that size is allocated, and the bytes are then
    /// viewed as the struct. `UnsafeMutableAudioBufferListPointer` is what lets Swift
    /// walk past the declared end safely.
    private static func outputDevices() -> [AudioOutputs.Device] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id -> AudioOutputs.Device? in
            var s = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &s, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let list = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { list.deallocate() }
            guard AudioObjectGetPropertyData(id, &s, 0, nil, &bytes, list) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
            let outputs = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard outputs > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            var t = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &t, 0, nil, &tSize, &transport)
            return AudioOutputs.Device(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, outputs: outputs,
                                       isVirtual: transport == kAudioDeviceTransportTypeVirtual)
        }
    }
}
