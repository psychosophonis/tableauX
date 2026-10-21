// clock-probe.swift — falsification probe for v3's network clock (Stage 0a).
//
// IDEA AT RISK: over the network the show will really use (university Wi-Fi),
// one Mac can estimate another Mac's clock with an NTP-style timestamp
// exchange, steady to within 5 ms for 95% of the time (target T11), once the
// estimate keeps only the fastest round trips. And, before that, that two Macs
// on that network can reach each other at all (T10): many campus networks
// block it ("client isolation"), and then nothing else in v3 matters.
//
// HOW IT WORKS. The joining Mac sends its time t1; the serving Mac stamps t2
// when the packet arrives and t3 as it replies; the joiner stamps t4 on
// arrival. Then, the standard NTP arithmetic:
//   round trip   = (t4 − t1) − (t3 − t2)          time spent on the network
//   clock offset = ((t2 − t1) + (t3 − t4)) / 2    server clock − joiner clock
// The offset formula assumes the trip out and the trip back took equally long.
// On Wi-Fi they often don't, but queueing only ever ADDS delay, so the samples
// with the SHORTEST round trip are the ones closest to that assumption. The
// estimate therefore uses, from the last 2 s of samples, the one with the
// smallest round trip: MIN-RTT FILTERING (Cristian's algorithm, as NTP does).
//
// WHAT WOULD FALSIFY IT: no replies (T10 fails), or a filtered estimate that
// wanders more than 5 ms from its trend (T11 fails). The trend itself is
// expected: two Macs' clocks run at slightly different rates, so the offset
// drifts in a straight line (a few to tens of parts per million). Steadiness is
// measured as the spread AROUND that line.
//
// THE CONTROL: `serve --fake-offset 7.5 --fake-drift 50` adds a known 7.5 ms
// offset and 50 ppm drift to the server's clock. A join against it must report
// about +7.5 ms and about 50 ppm. If it doesn't, the arithmetic is wrong and a
// pass on the real network would mean nothing.
//
// WHAT IT CAN'T TELL: whether the estimate is RIGHT, only whether it's steady.
// With no third clock to compare against, a steady but wrong estimate passes.
// Accuracy is tested by the sweep-line clips across two Macs (target T12).
//
// CONTROL RESULTS (2026-10-21, one Mac, loopback, server --fake-offset 7.5):
//   no noise, 20/s:        steady 0.05 ms, estimate 7.51 ms; drift 50 ppm read as 50.6
//   0–20 ms noise, 20/s:   raw 5.7 ms → filtered 0.40 ms (pass), estimate 7.30 ms
//   0–20 ms noise, 2/s:    filtered 2.77 ms (pass), estimate 5.64 ms: STEADY BUT
//                          WRONG by 1.9 ms, which is exactly the blind spot above
//   0–50 ms noise, 2/s:    filtered 11.7 ms: FAIL (so the probe can fail)
//   0–50 ms noise, 20/s:   raw 12.8 ms → filtered 1.08 ms (pass), estimate 6.30 ms
// So: sample often (20/s); and one-sided noise biases the estimate early by up
// to about a millisecond, small against a 33 ms frame. These runs test the
// probe, not any network: the real test is two Macs on the real Wi-Fi.
//
// The clock read is CLOCK_UPTIME_RAW, the same host clock the app's players
// follow (mach_absolute_time), so this measures the clock v3 would really use.
//
// Build:  swiftc -O proofs/clock-probe.swift -o .build/clock-probe
// Mac A:  .build/clock-probe serve
// Mac B:  .build/clock-probe join <address Mac A printed> [--seconds 600] [--csv file]

import Darwin
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let port: UInt16 = 47800

func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func fail(_ s: String) -> Never { print("error: \(s)"); exit(2) }

/// The value after `flag` on the command line, if present.
func option(_ flag: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
    return a[i + 1]
}

/// A packet is four 64-bit numbers: sequence number, t1, t2, t3.
typealias Packet = [UInt64]

func send(_ fd: Int32, _ p: Packet, to addr: sockaddr_in) {
    var a = addr
    _ = p.withUnsafeBytes { b in
        withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

/// Waits for one packet (up to the socket's timeout). Returns it and the sender.
func receive(_ fd: Int32) -> (Packet, sockaddr_in)? {
    var p: Packet = [0, 0, 0, 0]
    var from = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let n = p.withUnsafeMutableBytes { b in
        withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &len) }
        }
    }
    return n == 32 ? (p, from) : nil
}

func udpSocket(timeoutSeconds: Int) -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { fail("can't open a UDP socket") }
    var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

// MARK: serve

func serve() -> Never {
    let fakeOffsetNs = (Double(option("--fake-offset") ?? "0") ?? 0) * 1e6
    let fakePpm = Double(option("--fake-drift") ?? "0") ?? 0
    // Second control: a random 0…N ms delay on the way BACK, after t3 is
    // stamped. That's network noise the timestamps can't see, and it's
    // one-sided, so it biases the raw offset: exactly what the min-RTT filter
    // has to undo. With enough samples the filter should hold T11; with too
    // few (--rate 2 on the join side), T11 should FAIL.
    let fakeJitterMs = Double(option("--fake-jitter") ?? "0") ?? 0
    let start = nowNs()
    // The server's clock: the real one, plus the control's fake offset and drift.
    func serverTime() -> UInt64 {
        let t = nowNs()
        let skew = fakeOffsetNs + Double(t - start) * fakePpm / 1e6
        return UInt64(Int64(t) + Int64(skew))
    }

    let fd = udpSocket(timeoutSeconds: 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: 0)          // any interface
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard ok == 0 else { fail("can't listen on UDP port \(port) (already in use?)") }

    print("clock-probe serving on UDP port \(port). This Mac's addresses:")
    var ifs: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifs) == 0 {
        var p = ifs
        while let i = p {
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let name = String(cString: i.pointee.ifa_name)
                if name != "lo0" { print("  \(name): \(String(cString: host))   →  on the other Mac: clock-probe join \(String(cString: host))") }
            }
            p = i.pointee.ifa_next
        }
        freeifaddrs(ifs)
    }
    if fakeOffsetNs != 0 || fakePpm != 0 || fakeJitterMs != 0 {
        print(String(format: "CONTROL: server clock shifted by %.3f ms and %.1f ppm; replies delayed 0–%.0f ms",
                     fakeOffsetNs / 1e6, fakePpm, fakeJitterMs))
    }

    var served = 0
    while true {
        guard let (packet, from) = receive(fd) else { continue }
        var p = packet
        p[2] = serverTime()                     // t2: arrival
        p[3] = serverTime()                     // t3: reply
        if fakeJitterMs > 0 { usleep(useconds_t(Double.random(in: 0...fakeJitterMs) * 1000)) }
        send(fd, p, to: from)
        served += 1
        if served % 1200 == 0 { print("  answered \(served) requests") }
    }
}

// MARK: join

struct Sample { let seq: UInt64; let t1, t2, t3, t4: UInt64
    var roundTripMs: Double { (Double(t4 - t1) - Double(t3 - t2)) / 1e6 }
    var offsetMs: Double { ((Double(t2) - Double(t1)) + (Double(t3) - Double(t4))) / 2 / 1e6 }
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

/// Least-squares straight line through (x, y): the expected drift trend.
func lineFit(_ x: [Double], _ y: [Double]) -> (slope: Double, intercept: Double) {
    let n = Double(x.count), mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
    let sxy = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
    let slope = sxx > 0 ? sxy / sxx : 0
    return (slope, my - slope * mx)
}

func join(_ host: String) -> Never {
    let seconds = Double(option("--seconds") ?? "600") ?? 600
    let rate = Double(option("--rate") ?? "20") ?? 20
    let window = 2.0                           // seconds of samples the filter looks back over
    let csvPath = option("--csv") ?? "clock-probe-\(Int(Date().timeIntervalSince1970)).csv"

    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { fail("can't resolve \(host)") }
    let dest = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    freeaddrinfo(res)

    let fd = udpSocket(timeoutSeconds: 1)
    let lock = NSLock()
    var samples: [Sample] = []
    var running = true

    // Replies are read on their own thread, so a slow reply never delays the
    // next request (that would bias the round trips the filter depends on).
    Thread {
        while lock.withLock({ running }) {
            guard let (p, _) = receive(fd) else { continue }
            let t4 = nowNs()
            lock.withLock { samples.append(Sample(seq: p[0], t1: p[1], t2: p[2], t3: p[3], t4: t4)) }
        }
    }.start()

    print("joining \(host):\(port) for \(Int(seconds)) s at \(Int(rate)) requests/s …")
    let start = nowNs()
    var sent: UInt64 = 0
    var nextReport = 10.0
    while Double(nowNs() - start) / 1e9 < seconds {
        send(fd, [sent, nowNs(), 0, 0], to: dest)
        sent += 1
        usleep(useconds_t(1e6 / rate))
        let elapsed = Double(nowNs() - start) / 1e9
        let got = lock.withLock { samples.count }
        if elapsed > 5 && got == 0 {
            print("✗ T10 FAILED: no replies after 5 s. The Macs can't reach each other on this network")
            print("  (client isolation, a firewall on the serving Mac, or a wrong address).")
            exit(1)
        }
        if elapsed >= nextReport {
            nextReport += 10
            let recent = lock.withLock { samples.suffix(200) }
            print(String(format: "  %3.0f s: %d replies, median round trip %.1f ms",
                         elapsed, got, percentile(recent.map(\.roundTripMs), 0.5)))
        }
    }
    lock.withLock { running = false }
    usleep(1_200_000)                          // let the last replies land

    let all = lock.withLock { samples }.sorted { $0.seq < $1.seq }
    guard all.count > 10 else { fail("only \(all.count) replies; nothing to analyse") }

    // The filter, sample by sample: the offset of the fastest round trip in
    // the last `window` seconds. This is the estimate a player would act on.
    var filtered: [Double] = []
    var lo = 0
    for (i, s) in all.enumerated() {
        while Double(s.t1 - all[lo].t1) / 1e9 > window { lo += 1 }
        let best = all[lo...i].min { $0.roundTripMs < $1.roundTripMs }!
        filtered.append(best.offsetMs)
    }

    // Steadiness = spread around the drift trend (a straight line).
    let t = all.map { Double($0.t1 - start) / 1e9 }
    let raw = all.map(\.offsetMs)
    let fit = lineFit(t, filtered)
    let spread = zip(t, filtered).map { abs($1 - (fit.intercept + fit.slope * $0)) }
    let rawFit = lineFit(t, raw)
    let rawSpread = zip(t, raw).map { abs($1 - (rawFit.intercept + rawFit.slope * $0)) }
    let rtt = all.map(\.roundTripMs)

    var csv = "seq,t1_ns,t2_ns,t3_ns,t4_ns,round_trip_ms,offset_ms,filtered_offset_ms\n"
    for (s, f) in zip(all, filtered) {
        csv += "\(s.seq),\(s.t1),\(s.t2),\(s.t3),\(s.t4),\(s.roundTripMs),\(s.offsetMs),\(f)\n"
    }
    try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8)

    let lost = 100 * (1 - Double(all.count) / Double(sent))
    let p95 = percentile(spread, 0.95)
    print("")
    print(String(format: "replies: %d of %d sent (%.1f%% lost)", all.count, sent, lost))
    print(String(format: "round trip: median %.1f ms, 95%% %.1f ms, max %.1f ms",
                 percentile(rtt, 0.5), percentile(rtt, 0.95), rtt.max()!))
    print(String(format: "offset (server − this Mac): %.3f ms at start, drifting %.1f ppm",
                 fit.intercept, fit.slope * 1000))
    print(String(format: "steadiness, raw samples:      95%% within %.2f ms of the trend", percentile(rawSpread, 0.95)))
    print(String(format: "steadiness, min-RTT filtered: 95%% within %.2f ms of the trend", p95))
    print("samples written to \(csvPath)")
    print("")
    print("✓ T10 passed: the Macs reach each other on this network.")
    print(p95 <= 5
          ? String(format: "✓ T11 passed: estimate steady to %.2f ms (target ≤ 5 ms). Steady, not proven right: T12 tests accuracy.", p95)
          : String(format: "✗ T11 FAILED: estimate wanders %.2f ms (target ≤ 5 ms).", p95))
    exit(p95 <= 5 ? 0 : 1)
}

// MARK: main

switch CommandLine.arguments.dropFirst().first {
case "serve": serve()
case "join":
    guard CommandLine.arguments.count > 2 else { fail("usage: clock-probe join <address>") }
    join(CommandLine.arguments[2])
default:
    print("usage: clock-probe serve [--fake-offset ms] [--fake-drift ppm] [--fake-jitter ms]")
    print("       clock-probe join <address> [--seconds 600] [--rate 20] [--csv file]")
    exit(2)
}
