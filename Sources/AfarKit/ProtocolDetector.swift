import Foundation
import Network
import os

/// Finds out whether a computer answers with RDP or VNC, so adding one needs no choice.
///
/// VNC servers speak first ("RFB 003.008\n"). RDP servers wait for the client: they are sent the
/// first message of an RDP connection (an X.224 connection request) and answer with a TPKT
/// header. The probe ends there, before any sign-in.
public enum ProtocolDetector {
    public struct Result: Equatable, Sendable {
        public var remoteProtocol: RemoteProtocol
        public var port: UInt16
    }

    /// Probes `port`, or RDP's and VNC's default ports at once when it is nil. RDP wins when both
    /// answer: it carries sound, files and hardware video.
    public static func detect(host: String, port: UInt16?) async -> Result? {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        if let port {
            return await probe(host: host, port: port).map { Result(remoteProtocol: $0, port: port) }
        }
        async let rdp = probe(host: host, port: RemoteProtocol.rdp.defaultPort)
        async let vnc = probe(host: host, port: RemoteProtocol.vnc.defaultPort)
        let answers = await [rdp, vnc]
        if answers[0] == .rdp { return Result(remoteProtocol: .rdp, port: RemoteProtocol.rdp.defaultPort) }
        if answers[1] == .vnc { return Result(remoteProtocol: .vnc, port: RemoteProtocol.vnc.defaultPort) }
        return answers.compactMap { $0 }.first.map { Result(remoteProtocol: $0, port: $0.defaultPort) }
    }

    /// What the first bytes from a server say about it.
    static func classify(_ bytes: [UInt8]) -> RemoteProtocol? {
        if bytes.count >= 4, bytes.starts(with: Array("RFB ".utf8)) { return .vnc }
        if bytes.count >= 2, bytes[0] == 3, bytes[1] == 0 { return .rdp } // TPKT version 3
        return nil
    }

    /// Collects the first bytes, which may arrive in pieces, until they tell the protocol.
    private static func receive(_ connection: NWConnection, into received: [UInt8],
                                _ finish: @escaping @Sendable (RemoteProtocol?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, isComplete, error in
            let bytes = received + (data.map(Array.init) ?? [])
            if let found = classify(bytes) { return finish(found) }
            if isComplete || error != nil || bytes.count >= 16 { return finish(nil) }
            receive(connection, into: bytes, finish)
        }
    }

    /// TPKT + X.224 connection request + RDP negotiation request (TLS and NLA).
    static let rdpConnectionRequest: [UInt8] = [
        0x03, 0x00, 0x00, 0x13, 0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00,
    ]

    private static func probe(host: String, port: UInt16) async -> RemoteProtocol? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "Afar Desktop protocol probe")
        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: RemoteProtocol?) {
                guard finished.withLock({ done in defer { done = true }; return !done }) else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            queue.asyncAfter(deadline: .now() + 3) { finish(nil) }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Give a VNC server a moment to speak first; then try RDP's opening.
                    receive(connection, into: [], finish)
                    queue.asyncAfter(deadline: .now() + 0.8) {
                        guard !finished.withLock({ $0 }) else { return }
                        connection.send(content: Data(rdpConnectionRequest), completion: .contentProcessed { _ in })
                    }
                case .failed, .cancelled:
                    finish(nil)
                case .waiting(let error):
                    // Waiting can be a passing state (network policy still being evaluated);
                    // a refused port is final.
                    if case .posix(.ECONNREFUSED) = error { finish(nil) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}
