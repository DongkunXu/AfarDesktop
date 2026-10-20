import AfarEngine
import CommonCrypto
import CryptoKit
import Foundation

/// Agrees on a security type with the server and authenticates (RFB 6.1.2 and 7.2).
///
/// Supported, most secure first: VeNCrypt (19) with any of its TLS or X.509 subtypes, Apple
/// Remote Desktop's Diffie-Hellman login (30, macOS Screen Sharing), VNC password (2) and None (1).
struct VNCSecurity {
    let stream: VNCStream
    let host: String
    let port: UInt16
    /// Protocol minor version agreed with the server: 3, 7 or 8.
    let minor: Int
    /// Asks for credentials; throws `VNCError.cancelled` when the user declines.
    let credentials: (_ needsUsername: Bool) throws -> Credentials
    /// Decides on a TLS certificate; throws to reject it.
    let trust: (AfarPeerCertificate) throws -> Void

    enum SecurityType: UInt8 {
        case none = 1, vncPassword = 2, veNCrypt = 19, appleDH = 30
    }

    static let preference: [SecurityType] = [.veNCrypt, .appleDH, .vncPassword, .none]

    func negotiate() throws {
        let type: SecurityType
        if minor == 3 {
            // 3.3: the server decides.
            let chosen = try stream.u32()
            guard chosen != 0 else { throw VNCError.refused(try stream.string()) }
            guard let known = SecurityType(rawValue: UInt8(truncatingIfNeeded: chosen)),
                  known == .none || known == .vncPassword else {
                throw VNCError.unsupported(Self.describe([UInt8(truncatingIfNeeded: chosen)]))
            }
            type = known
        } else {
            let count = Int(try stream.u8())
            guard count > 0 else { throw VNCError.refused(try stream.string()) }
            let offered = try stream.bytes(count)
            guard let chosen = Self.preference.first(where: { offered.contains($0.rawValue) }) else {
                throw VNCError.unsupported(Self.describe(offered))
            }
            stream.write([chosen.rawValue])
            type = chosen
        }

        var expectsResult = minor >= 8 || type != .none
        switch type {
        case .none: break
        case .vncPassword: try vncPassword(try credentials(false).password)
        case .appleDH: try appleDH()
        case .veNCrypt: expectsResult = try veNCrypt() || minor >= 8
        }
        if expectsResult { try securityResult() }
    }

    private func securityResult() throws {
        guard try stream.u32() != 0 else { return }
        throw VNCError.authentication(minor >= 8 ? try stream.string() : nil)
    }

    /// Names of the offered types, for the error shown when none is usable.
    static func describe(_ types: [UInt8]) -> String {
        let names: [UInt8: String] = [5: "RSA-AES", 6: "RSA-AES", 129: "RSA-AES-256", 16: "Tight",
                                      33: "Apple", 35: "Apple", 36: "Apple"]
        return types.map { type in names[type].map { "\($0) (\(type))" } ?? String(type) }
            .joined(separator: ", ")
    }

    // MARK: VNC password

    /// DES-encrypts the server's 16-byte challenge with the password (up to 8 characters), whose
    /// bits are reversed in each byte, as VNC has always done.
    private func vncPassword(_ password: String) throws {
        let challenge = try stream.bytes(16)
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.prefix(8).enumerated() { key[index] = Self.reversedBits(byte) }
        stream.write(try Self.crypt(challenge, key: key, algorithm: CCAlgorithm(kCCAlgorithmDES)))
    }

    static func reversedBits(_ byte: UInt8) -> UInt8 {
        var input = byte, output: UInt8 = 0
        for _ in 0..<8 {
            output = output << 1 | input & 1
            input >>= 1
        }
        return output
    }

    /// One-block-at-a-time (ECB) encryption, which both VNC password and Apple DH use.
    static func crypt(_ input: [UInt8], key: [UInt8], algorithm: CCAlgorithm) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode), key, key.count,
                             nil, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess else { throw VNCError.protocolError("encryption failed (\(status))") }
        return output
    }

    // MARK: Apple Remote Desktop (30)

    /// Diffie-Hellman over the server's parameters; the MD5 of the shared secret is an AES key for
    /// 128 bytes holding the user name and password (64 each, NUL-terminated, random filling).
    private func appleDH() throws {
        let generator = try stream.bytes(2)
        let length = Int(try stream.u16())
        guard (16...1024).contains(length) else { throw VNCError.protocolError("Apple DH key of \(length) bytes") }
        let prime = try stream.bytes(length)
        let serverPublic = try stream.bytes(length)
        let login = try credentials(true)

        var clientPublic = [UInt8](repeating: 0, count: length)
        var secret = [UInt8](repeating: 0, count: length)
        guard afar_dh_agree(generator, generator.count, prime, serverPublic, length, &clientPublic, &secret) else {
            throw VNCError.protocolError("Diffie-Hellman agreement failed")
        }
        let key = Array(Insecure.MD5.hash(data: secret))

        var plain = (0..<128).map { _ in UInt8.random(in: 0...255) }
        for (offset, text) in [(0, login.username), (64, login.password)] {
            let bytes = Array(text.utf8.prefix(63))
            plain.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            plain[offset + bytes.count] = 0
        }
        stream.write(try Self.crypt(plain, key: key, algorithm: CCAlgorithm(kCCAlgorithmAES)) + clientPublic)
    }

    // MARK: VeNCrypt (19)

    enum VeNCryptSubtype: UInt32 {
        case plain = 256, tlsNone = 257, tlsVNC = 258, tlsPlain = 259
        case x509None = 260, x509VNC = 261, x509Plain = 262

        var usesTLS: Bool { self != .plain }
        var usesCertificate: Bool { rawValue >= 260 }
    }

    static let veNCryptPreference: [VeNCryptSubtype] = [.x509Plain, .x509VNC, .x509None, .tlsPlain, .tlsVNC, .tlsNone, .plain]

    /// Returns whether a security result follows regardless of the protocol version.
    private func veNCrypt() throws -> Bool {
        let major = try stream.u8(), minorVersion = try stream.u8()
        guard (major, minorVersion) >= (0, 2) else { throw VNCError.unsupported("VeNCrypt \(major).\(minorVersion)") }
        stream.write([0, 2])
        guard try stream.u8() == 0 else { throw VNCError.unsupported("VeNCrypt 0.2") }
        let count = Int(try stream.u8())
        let offered = try (0..<count).map { _ in try stream.u32() }
        guard let subtype = Self.veNCryptPreference.first(where: { offered.contains($0.rawValue) }) else {
            throw VNCError.unsupported("VeNCrypt " + offered.map(String.init).joined(separator: ", "))
        }
        var message = VNCMessage()
        message.u32(subtype.rawValue)
        stream.write(message.bytes)
        guard try stream.u8() == 1 else { throw VNCError.unsupported("VeNCrypt subtype \(subtype.rawValue)") }

        if subtype.usesTLS {
            let peer = try stream.startTLS(serverName: host, anonymous: !subtype.usesCertificate)
            if subtype.usesCertificate { try trust(peer) }
        }
        switch subtype {
        case .tlsNone, .x509None:
            break
        case .tlsVNC, .x509VNC:
            try vncPassword(try credentials(false).password)
        case .plain, .tlsPlain, .x509Plain:
            let login = try credentials(true)
            let user = Array(login.username.utf8), password = Array(login.password.utf8)
            var plain = VNCMessage()
            plain.u32(UInt32(user.count))
            plain.u32(UInt32(password.count))
            plain.append(user)
            plain.append(password)
            stream.write(plain.bytes)
        }
        return true
    }
}

/// Fingerprints of the certificates the user accepted, one file per host and port: the user is
/// asked the first time and again only when the certificate changes.
struct VNCTrustStore {
    let directory: URL

    private func file(host: String, port: UInt16) -> URL {
        let name = "\(host)_\(port)".lowercased()
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return AppPaths.acceptedCertificate(named: name, in: directory, remoteProtocol: .vnc)
    }

    func fingerprint(host: String, port: UInt16) -> String? {
        (try? String(contentsOf: file(host: host, port: port), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func accept(_ fingerprint: String, host: String, port: UInt16) {
        let url = file(host: host, port: port)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (fingerprint + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
