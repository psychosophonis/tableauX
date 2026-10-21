// work-switch-probe.swift — falsification probe for v4 playlists (P0).
//
// IDEA AT RISK (docs/architecture.md § v4 › Riskiest assumption): a Mac can
// tear down one work's players and build the next work's — three 4K videos —
// inside the black gap between works (3 s), over and over for hours, with load
// times that don't creep up and memory that doesn't grow. v1 built its players
// once per show, so nothing so far has shown that doing it every few minutes
// is clean. A playlist does it ~10 times an hour, all day.
//
// HOW THIS TRIES TO KILL IT: cycle much faster than a real playlist (default a
// new "work" every 10 s, i.e. 360 changes an hour), each time building three
// players exactly as the app does (composition, AVPlayer on the host clock,
// preroll), playing them while pulling every decoded frame through
// AVPlayerItemVideoOutput (so decoding really happens, as on screen), then
// releasing everything. Per cycle it logs the load time (build start → all
// prerolled) and the process's memory footprint (phys_footprint, the number
// Activity Monitor shows as "Memory").
//
// WHAT WOULD FALSIFY IT (set before running):
//   - 95th-percentile load time > 3 s (the gap), or
//   - load time creeping: mean of the last 10% of cycles > 1.5 × the first 10%, or
//   - memory growing: slope of footprint after the first 5 cycles > 25 MB/hour.
//
// THE CONTROL: --leak keeps every old player alive instead of releasing it,
// which is the bug this probe exists to catch. It MUST fail the memory test;
// if it doesn't, a pass on a real run means nothing.
//
// WHAT IT CAN'T TELL: anything about two Macs, or the screen. It has no
// display; decode is forced by pulling frames, as the sync probe did.
//
// Build and run:
//   swiftc -O proofs/work-switch-probe.swift -o .build/work-switch-probe
//   .build/work-switch-probe [--minutes 60] [--period 10] [--leak] file1 file2 file3

import AVFoundation
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
let hostClock = CMClockGetHostTimeClock()

/// The process's memory as Activity Monitor counts it, in MB.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
}

func option(_ flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
}

/// Least-squares slope of y over x.
func slope(_ x: [Double], _ y: [Double]) -> Double {
    let n = Double(x.count), mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
    let sxy = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
    return sxx > 0 ? sxy / sxx : 0
}

/// One work's players, built the way Playback builds them.
@MainActor func buildWork(_ urls: [URL]) async throws -> [(AVPlayer, AVPlayerItemVideoOutput)] {
    var built: [(AVPlayer, AVPlayerItemVideoOutput)] = []
    for url in urls {
        let asset = AVURLAsset(url: url)
        let clip = try await asset.load(.duration)
        let comp = AVMutableComposition()
        // A playlist work plays once (or N times): a short composition, not v1's 24 h.
        try await comp.insertTimeRange(CMTimeRange(start: .zero, duration: clip), of: asset, at: .zero)
        let item = AVPlayerItem(asset: comp)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.masterClock = hostClock
        player.isMuted = true
        built.append((player, output))
    }
    while let p = built.first(where: { $0.0.currentItem?.status != .readyToPlay }) {
        if p.0.currentItem?.status == .failed { throw p.0.currentItem?.error ?? CocoaError(.fileReadCorruptFile) }
        try await Task.sleep(for: .milliseconds(10))
    }
    for (p, _) in built { _ = await p.preroll(atRate: 1) }
    return built
}

@MainActor func run() async throws -> Int32 {
    let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") && Double($0) == nil }
    guard !files.isEmpty else { print("usage: work-switch-probe [--minutes 60] [--period 10] [--leak] file…"); return 2 }
    let urls = files.map { URL(fileURLWithPath: $0) }
    let minutes = Double(option("--minutes") ?? "60") ?? 60
    let period = Double(option("--period") ?? "10") ?? 10
    let leak = CommandLine.arguments.contains("--leak")
    var kept: [[(AVPlayer, AVPlayerItemVideoOutput)]] = []     // the control's deliberate leak

    print("cycling \(urls.count) item(s) every \(Int(period)) s for \(Int(minutes)) min\(leak ? ", CONTROL: leaking every work" : "")")
    let start = Date()
    var loads: [Double] = [], mems: [Double] = [], times: [Double] = []
    var cycle = 0
    while Date().timeIntervalSince(start) < minutes * 60 {
        cycle += 1
        let t0 = Date()
        let work = try await buildWork(urls)
        let load = Date().timeIntervalSince(t0)
        let h0 = CMClockGetTime(hostClock) + CMTime(seconds: 0.2, preferredTimescale: 1_000_000_000)
        for (p, _) in work { p.setRate(1, time: .zero, atHostTime: h0) }
        // Play for the rest of the period, pulling every decoded frame.
        var frames = 0
        let until = t0.addingTimeInterval(period)
        while Date() < until {
            let host = CMClockGetTime(hostClock)
            for (p, out) in work {
                guard let item = p.currentItem else { continue }
                let t = out.itemTime(forHostTime: host.seconds)
                if out.hasNewPixelBuffer(forItemTime: t), out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil { frames += 1 }
                _ = item
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Tear down as the app would: stop, detach the item, drop the references.
        for (p, _) in work { p.pause(); p.replaceCurrentItem(with: nil) }
        if leak { kept.append(work) }
        let mem = footprintMB()
        loads.append(load); mems.append(mem); times.append(Date().timeIntervalSince(start) / 3600)
        print(String(format: "cycle %4d: load %.2f s, %4d frames, memory %.0f MB", cycle, load, frames, mem))
    }
    _ = kept.count

    guard loads.count >= 10 else { print("too few cycles to judge"); return 2 }
    let sorted = loads.sorted()
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
    let tenth = max(1, loads.count / 10)
    let first = loads.prefix(tenth).reduce(0, +) / Double(tenth)
    let last = loads.suffix(tenth).reduce(0, +) / Double(tenth)
    let warm = min(5, loads.count - 2)
    let growth = slope(Array(times.dropFirst(warm)), Array(mems.dropFirst(warm)))      // MB per hour
    print("")
    print(String(format: "load: median %.2f s, 95%% %.2f s, max %.2f s", sorted[sorted.count / 2], p95, sorted.last!))
    print(String(format: "load creep: first 10%% %.2f s, last 10%% %.2f s (×%.2f)", first, last, last / first))
    print(String(format: "memory: %.0f MB after warm-up, %.0f MB at end, slope %+.1f MB/hour", mems[warm], mems.last!, growth))
    var ok = true
    if p95 > 3 { print("✗ load p95 over the 3 s gap"); ok = false }
    if last > 1.5 * first { print("✗ load times creep up"); ok = false }
    if growth > 25 { print("✗ memory grows"); ok = false }
    print(ok ? "✓ survived: works can be swapped inside the gap without creep or growth" : "✗ FALSIFIED")
    return ok ? 0 : 1
}

Task { @MainActor in
    do { exit(try await run()) } catch { print("error: \(error)"); exit(2) }
}
RunLoop.main.run()
