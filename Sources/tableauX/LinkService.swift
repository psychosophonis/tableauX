import Foundation
import Network
import PlayerCore

// [claude] v4 P3b: the TCP link between the conductor and each player
// (docs/architecture.md § v4 › Media on several Macs). The messages and their
// framing are PlayerCore's (ShowLink.swift); this is only the transport.
//
// Why Network.framework here when the clock uses BSD sockets: the clock's
// reasons were TIMESTAMPS (a packet must be stamped the instant it lands).
// Nothing here is timed. What TCP needs instead is connection state,
// reconnecting, and reads that may end anywhere in a message, which
// Network.framework's NWListener / NWConnection give directly. Its callbacks
// run on one private serial queue, so the state below is only touched there;
// messages are handed to the main actor, which owns the show.

enum Link {
    static let port: UInt16 = 47801
    /// [claude] P4b: the Bonjour service type a conductor announces, so a
    /// player finds it without anyone typing an address. Listed under
    /// NSBonjourServices in the app's Info.plist, which macOS requires
    /// before an app may look for it on the local network.
    static let serviceType = "_tableaux._tcp"

    /// TCP over IPv4 only: the clock (BSD sockets, AF_INET) needs the
    /// conductor's IPv4 address, which a discovered connection then gives.
    static var ipv4TCP: NWParameters {
        let p = NWParameters.tcp
        (p.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        return p
    }

    /// The IPv4 address at the other end of a ready connection, e.g. "192.168.1.46".
    static func remoteIPv4(_ c: NWConnection) -> String? {
        guard case .hostPort(let host, _) = c.currentPath?.remoteEndpoint, case .ipv4(let a) = host else { return nil }
        return "\(a)".components(separatedBy: "%").first      // drop any "%en0" interface suffix
    }

    /// Reads from `c` until it closes, feeding a framing Reader and passing
    /// each whole message on. Recursive by design: each completed receive
    /// asks for the next, the usual Network.framework read loop.
    static func readLoop(_ c: NWConnection, reader: LinkFraming.Reader = .init(),
                         onMessage: @escaping @Sendable (LinkMessage) -> Void,
                         onClose: @escaping @Sendable (String) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            var r = reader
            if let data, !data.isEmpty {
                do { try r.feed(data).forEach(onMessage) } catch {
                    onClose("refused a message: \(error)")
                    return
                }
            }
            if let error { onClose("\(error)"); return }
            if done { onClose("closed by the other end"); return }
            readLoop(c, reader: r, onMessage: onMessage, onClose: onClose)
        }
    }

    static func send(_ m: LinkMessage, on c: NWConnection) {
        guard let data = try? LinkFraming.frame(m) else { return }
        c.send(content: data, completion: .contentProcessed { _ in })
    }
}

/// The conductor's end: accepts players, hears their messages, sends them the show.
final class LinkServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tableauX.link.server")
    private var peers: [ObjectIdentifier: NWConnection] = [:]      // on `queue` only
    private let onMessage: @Sendable (LinkMessage, ObjectIdentifier) -> Void
    private let onClose: @Sendable (ObjectIdentifier) -> Void

    /// Callbacks arrive on the link's queue; the caller hops to the main actor.
    /// `advertiseAs`: the name players see this conductor by (P4b, Bonjour).
    init(advertiseAs name: String,
         onMessage: @escaping @Sendable (LinkMessage, ObjectIdentifier) -> Void,
         onClose: @escaping @Sendable (ObjectIdentifier) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true          // a quick restart can listen again at once
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Link.port)!)
        listener.service = NWListener.Service(name: name, type: Link.serviceType)
        self.onMessage = onMessage
        self.onClose = onClose
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { NSLog("link: listener failed: %@", "\(e)") }
        }
        listener.start(queue: queue)
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        peers[id] = c
        NSLog("link: player connected from %@", "\(c.endpoint)")
        c.start(queue: queue)
        Link.readLoop(c, onMessage: { [weak self] m in self?.onMessage(m, id) },
                      onClose: { [weak self] why in
                          NSLog("link: player %@ gone (%@)", "\(c.endpoint)", why)
                          self?.drop(id)
                      })
    }

    private func drop(_ id: ObjectIdentifier) {
        queue.async { [self] in
            guard let c = peers.removeValue(forKey: id) else { return }
            c.cancel()
            onClose(id)
        }
    }

    /// Sends to one player, or to all (`to: nil`).
    func send(_ m: LinkMessage, to id: ObjectIdentifier? = nil) {
        queue.async { [self] in
            for (pid, c) in peers where id == nil || pid == id { Link.send(m, on: c) }
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            peers.values.forEach { $0.cancel() }
            peers = [:]
        }
    }
}

/// A player's end: connects to the conductor, and keeps reconnecting every
/// 2 s whenever the connection is down (conductor not started yet, Wi-Fi
/// dropped, conductor restarted). Each new connection is a fresh start, so
/// the player re-sends everything it has (`onConnected`).
///
/// [claude] P4b: with no address (`host` nil) it FINDS the conductor by
/// Bonjour: it browses for `_tableaux._tcp`, joins if exactly one conductor
/// answers, and reports that conductor's name and IPv4 address so the clock
/// can follow it too. Several conductors: it never guesses (a wrong guess
/// would join another class's show); it reports their names and waits.
final class LinkClient: @unchecked Sendable {
    private let host: String?
    private let queue = DispatchQueue(label: "tableauX.link.client")
    private var connection: NWConnection?          // on `queue` only
    private var browser: NWBrowser?                // on `queue` only
    private var stopped = false
    private let onConnected: @Sendable (_ name: String, _ ipv4: String?) -> Void
    private let onMessage: @Sendable (LinkMessage) -> Void
    private let onDisconnected: @Sendable () -> Void
    private let onSeveral: @Sendable ([String]) -> Void

    init(conductor host: String?, onConnected: @escaping @Sendable (_ name: String, _ ipv4: String?) -> Void,
         onMessage: @escaping @Sendable (LinkMessage) -> Void,
         onDisconnected: @escaping @Sendable () -> Void,
         onSeveral: @escaping @Sendable ([String]) -> Void = { _ in }) {
        self.host = host
        self.onConnected = onConnected
        self.onMessage = onMessage
        self.onDisconnected = onDisconnected
        self.onSeveral = onSeveral
        queue.async { [self] in connect() }
    }

    private func connect() {
        guard !stopped else { return }
        if let host {
            open(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Link.port)!, using: Link.ipv4TCP), name: host)
        } else {
            browse()
        }
    }

    private func browse() {
        let b = NWBrowser(for: .bonjour(type: Link.serviceType, domain: nil), using: .tcp)
        browser = b
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.browser === b else { return }
            let found = results.compactMap { r -> (NWEndpoint, String)? in
                if case .service(let name, _, _, _) = r.endpoint { return (r.endpoint, name) }
                return nil
            }
            if found.count == 1 {
                b.cancel()
                self.browser = nil
                NSLog("link: found conductor %@", found[0].1)
                self.open(NWConnection(to: found[0].0, using: Link.ipv4TCP), name: found[0].1)
            } else if found.count > 1 {
                self.onSeveral(found.map(\.1).sorted())
            }
        }
        b.start(queue: queue)
    }

    private func open(_ c: NWConnection, name: String) {
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                NSLog("link: connected to %@", name)
                self.onConnected(name, Link.remoteIPv4(c))
                Link.readLoop(c, onMessage: self.onMessage, onClose: { [weak self] why in
                    NSLog("link: conductor gone (%@)", why)
                    self?.retry(c)
                })
            // .waiting = can't reach it right now (refused, no route). Network
            // framework would wait for a network change before trying again;
            // a conductor that simply hasn't started yet needs a retry instead.
            case .waiting, .failed: self.retry(c)
            default: break
            }
        }
        c.start(queue: queue)
    }

    /// Drop connection `c` (if it is still the current one) and try again in 2 s.
    private func retry(_ c: NWConnection) {
        queue.async { [self] in
            guard connection === c else { return }
            connection = nil
            c.cancel()
            onDisconnected()
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
        }
    }

    func send(_ m: LinkMessage) {
        queue.async { [self] in if let c = connection, c.state == .ready { Link.send(m, on: c) } }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            connection?.cancel()
            connection = nil
            browser?.cancel()
            browser = nil
        }
    }
}
