import Darwin
import Foundation
import PlayerCore

// [claude] The v3 clock over UDP (docs/architecture.md § v3 › Clock, Wire):
// `proofs/clock-probe.swift`, which passed on the university Wi-Fi, turned
// into two components the app can start and stop.
//
// Why BSD sockets and dedicated threads, not Network.framework or async/await:
// the timestamps are the measurement. t2 (conductor) and t4 (player) must be
// read the instant a packet arrives. A thread that does nothing but wait in
// recvfrom() and stamp the time gives that. Anything that queues the arrival
// for later (a dispatch queue under load, the main actor while SwiftUI is
// drawing) adds a delay the arithmetic can't see, which is exactly the
// one-sided error the min-RTT filter is there to remove. It is also the code
// the real-network run proved, so it is the least risky way to start.

/// The host clock in nanoseconds. CLOCK_UPTIME_RAW is mach_absolute_time in
/// nanoseconds, the clock AVPlayer's host time follows, so conductor time
/// estimated against it can drive playback directly (Stage 3).
func hostNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

enum ClockServiceError: Error, CustomStringConvertible {
    case socket, bind(UInt16), resolve(String)
    var description: String {
        switch self {
        case .socket: return "couldn't open a UDP socket"
        case .bind(let p): return "couldn't listen on UDP port \(p) (is another copy of tableauX, or the probe, running?)"
        case .resolve(let h): return "couldn't find the address \(h)"
        }
    }
}

/// The small amount of socket plumbing both sides share.
private enum UDP {
    static let port: UInt16 = 47800

    /// A UDP socket whose receive gives up after 0.1 s, so a thread waiting
    /// in it notices a stop request within that time. This timeout is the
    /// only thing that wakes it: shutdown() does not interrupt a blocked UDP
    /// recvfrom on macOS (measured 2026-10-21: every stop took the full
    /// timeout, then 1 s). Waking 10 times a second to check a flag costs
    /// nothing; a 1 s freeze of setup on every mode change did.
    static func open() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ClockServiceError.socket }
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func send(_ fd: Int32, _ bytes: [UInt8], to addr: sockaddr_in) {
        var a = addr
        _ = bytes.withUnsafeBytes { b in
            withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// One datagram's bytes and its sender, or nil on timeout. The caller
    /// decides what it is: 32 bytes is a clock packet, 40 a show state.
    static func receive(_ fd: Int32) -> ([UInt8], sockaddr_in)? {
        var buf = [UInt8](repeating: 0, count: 64)    // larger than a packet, so oversize ones are seen and refused
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buf.withUnsafeMutableBytes { b in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &len) }
            }
        }
        guard n > 0 else { return nil }
        return (Array(buf[0..<n]), from)
    }

    /// Stops a component and frees its socket, in an order that is safe:
    /// 1. clear its running flag, so its threads leave their loops (within the
    ///    0.1 s receive timeout);
    /// 2. wait until every thread using the socket has finished;
    /// 3. only then close() it.
    /// Closing first would be a USE-AFTER-CLOSE race: a thread still sending
    /// could write to the number after the system had reused it for another
    /// file. And until close(), the port stays taken, so a stop that returned
    /// early made the next bind fail (seen on 2026-10-21, at launch).
    static func shutDown(_ fd: Int32, running stop: () -> Void, threads: [DispatchSemaphore]) {
        stop()
        threads.forEach { $0.wait() }
        close(fd)
    }

    static func name(_ a: sockaddr_in) -> String {
        var addr = a.sin_addr
        var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &out, socklen_t(out.count))
        return String(cString: out)
    }

    /// This Mac's IPv4 addresses, without loopback: what a player types in.
    static func localAddresses() -> [String] {
        var result: [String] = []
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0 else { return [] }
        var p = ifs
        while let i = p {
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), String(cString: i.pointee.ifa_name) != "lo0" {
                result.append(name(a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }))
            }
            p = i.pointee.ifa_next
        }
        freeifaddrs(ifs)
        return result
    }
}

/// Conductor side: answers every clock request, stamping t2 on arrival and t3
/// on reply. Stateless per request, so any number of players can ask.
///
/// `@unchecked Sendable`: the receive thread and the main actor share
/// `askers` and `running`, and every touch of them goes through `lock`. The
/// compiler can't see a lock, so the promise is made by hand, here, once.
final class ClockServer: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var running = true
    private var askers: [String: (addr: sockaddr_in, last: UInt64)] = [:]   // player → its socket, last request (host ns)
    private var state: ShowState?                    // what the show is doing (§ v3 › Show state)

    init() throws {
        fd = try UDP.open()
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UDP.port.bigEndian
        addr.sin_addr = in_addr(s_addr: 0)                // every interface
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(fd); throw ClockServiceError.bind(UDP.port) }
        let thread = Thread { [self] in serve() }
        thread.name = "tableauX clock server"
        thread.qualityOfService = .userInteractive     // stamping late is measurement error
        thread.start()
    }

    private func serve() {
        while lock.withLock({ running }) {
            guard let (bytes, from) = UDP.receive(fd) else { continue }
            let arrived = hostNanos()                    // t2: as soon as it arrived
            guard var p = ClockPacket(bytes: bytes) else { continue }
            p.t2 = arrived
            p.t3 = hostNanos()                           // as it leaves
            UDP.send(fd, p.bytes, to: from)
            let name = UDP.name(from)
            lock.withLock { askers[name] = (from, arrived) }
        }
        finished.signal()
    }

    /// The show's state changed: send it now and twice more over 0.3 s, so
    /// one lost packet doesn't cost a player its start.
    func publish(_ s: ShowState) {
        lock.withLock { state = s }
        broadcast()
        for delay in [0.1, 0.3] { DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in broadcast() } }
    }

    /// Sends the current state to every player heard from in the last 10 s.
    /// Called on every change and once a second (AppModel's status timer), so
    /// a player that joins or misses packets catches up within a second.
    ///
    /// Sending happens under the lock, and only while running: stop() clears
    /// `running` under the same lock before it closes the socket, so a late
    /// broadcast can never write to a closed (or reused) descriptor.
    func broadcast() {
        lock.withLock {
            guard running, let state else { return }
            let now = hostNanos()
            for (_, a) in askers where Double(now - a.last) / 1e9 <= 10 { UDP.send(fd, state.bytes, to: a.addr) }
        }
    }

    /// Players heard from in the last `seconds`.
    func players(within seconds: Double = 10) -> [String] {
        lock.withLock {
            // `now` is read inside the lock: every stored stamp was taken
            // before its write got the lock, so none is later than `now`, and
            // the unsigned subtraction can't underflow (which would trap).
            let now = hostNanos()
            return askers.filter { Double(now - $0.value.last) / 1e9 <= seconds }.keys.sorted()
        }
    }

    var addresses: [String] { UDP.localAddresses() }

    private let finished = DispatchSemaphore(value: 0)

    /// Returns once the port is free, so a restart can bind it at once.
    func stop() { UDP.shutDown(fd, running: { lock.withLock { running = false } }, threads: [finished]) }
}

/// Player side: asks the conductor 20 times a second and keeps the running
/// estimate of its clock (`ClockEstimator`), plus T11's steadiness, live.
final class ClockClient: @unchecked Sendable {
    /// What setup shows; a copy, so the main actor never holds the lock.
    struct Status {
        var conductor: String
        var repliesPerSecond: Double
        var offset: Double?            // conductor − this Mac, seconds
        var steadiness: Double?        // p95 spread around the trend, seconds
        var drift: Double?             // per second (×1e6 = ppm)
        var secondsSinceReply: Double? // nil = no reply yet
        var secondsRunning: Double
    }

    static let rate = 20.0             // requests per second (v3 § Clock: 2/s was too few)

    let conductor: String
    private let fd: Int32
    private let dest: sockaddr_in
    private let lock = NSLock()
    private var running = true
    private var estimator = ClockEstimator()
    private var meter = SteadinessMeter()
    private var replyTimes: [UInt64] = []     // host ns of replies in the last second
    private var lastReply: UInt64?
    private let started = hostNanos()

    /// Called on the receive thread with every show state from the conductor.
    private let onState: @Sendable (ShowState) -> Void

    init(conductor: String, onState: @escaping @Sendable (ShowState) -> Void) throws {
        self.conductor = conductor
        self.onState = onState
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(conductor, String(UDP.port), &hints, &res) == 0, let ai = res else {
            throw ClockServiceError.resolve(conductor)
        }
        dest = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        freeaddrinfo(res)
        fd = try UDP.open()

        // Two threads, as in the probe: replies are read on their own thread,
        // so a slow reply never delays the next request. Delaying requests
        // behind replies would couple the round trips the filter compares.
        let receiver = Thread { [self] in receive() }
        receiver.name = "tableauX clock receive"
        receiver.qualityOfService = .userInteractive
        receiver.start()
        let sender = Thread { [self] in send() }
        sender.name = "tableauX clock send"
        sender.qualityOfService = .userInteractive
        sender.start()
    }

    private func send() {
        var seq: UInt64 = 0
        while lock.withLock({ running }) {
            UDP.send(fd, ClockPacket(seq: seq, t1: hostNanos()).bytes, to: dest)
            seq += 1
            usleep(useconds_t(1e6 / Self.rate))
        }
        senderDone.signal()
    }

    private let senderDone = DispatchSemaphore(value: 0)
    private let receiverDone = DispatchSemaphore(value: 0)

    private func receive() {
        while lock.withLock({ running }) {
            guard let (bytes, _) = UDP.receive(fd) else { continue }
            let t4 = hostNanos()
            if let s = ShowState(bytes: bytes) { onState(s); continue }
            guard let p = ClockPacket(bytes: bytes) else { continue }
            let host = Double(t4) / 1e9
            lock.withLock {
                // One receive thread, so samples reach the estimator in order
                // of t4, which `ClockEstimator.add` requires.
                estimator.add(p.sample(t4: t4))
                if let c = estimator.conductorTime(host: host) { meter.add(time: host, offset: c - host) }
                replyTimes.append(t4)
                replyTimes.removeAll { t4 - $0 > 1_000_000_000 }
                lastReply = t4
            }
        }
        receiverDone.signal()
    }

    /// Conductor time at this Mac's host time `host` (seconds), once known.
    /// Stage 3 schedules playback with this.
    func conductorTime(host: Double) -> Double? { lock.withLock { estimator.conductorTime(host: host) } }

    /// This Mac's host time at conductor time `show`. The inverse of
    /// conductorTime, using the offset as it is now: the offset changes by
    /// parts per million, so over the seconds ahead that playback schedules,
    /// "as it is now" is exact to well under a microsecond.
    func hostTime(conductor show: Double) -> Double? {
        lock.withLock {
            let now = Double(hostNanos()) / 1e9
            return estimator.conductorTime(host: now).map { show - ($0 - now) }
        }
    }

    var status: Status {
        lock.withLock {
            let now = hostNanos()          // inside the lock: see ClockServer.players
            let host = Double(now) / 1e9
            return Status(conductor: conductor,
                          repliesPerSecond: Double(replyTimes.filter { now - $0 <= 1_000_000_000 }.count),
                          offset: estimator.conductorTime(host: host).map { $0 - host },
                          steadiness: meter.p95Spread,
                          drift: estimator.drift,
                          secondsSinceReply: lastReply.map { Double(now - $0) / 1e9 },
                          secondsRunning: Double(now - started) / 1e9)
        }
    }

    func stop() {
        UDP.shutDown(fd, running: { lock.withLock { running = false } }, threads: [senderDone, receiverDone])
    }
}
