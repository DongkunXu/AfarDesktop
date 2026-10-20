import CoreGraphics
import Foundation

public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Why a session ended, grouped for presentation.
public struct SessionError: Error, Equatable, Sendable {
    public enum Reason: Sendable {
        case authentication, certificate, hostNotFound, unreachable, replaced, timeout
        case serverDenied, networkLost, unsupported, other
    }

    public var reason: Reason
    /// The protocol's own error code, for diagnostics (FreeRDP's for RDP; 0 when there is none).
    public var code: UInt32
    /// The protocol's own description, for diagnostics.
    public var detail: String?

    public init(reason: Reason, code: UInt32 = 0, detail: String? = nil) {
        self.reason = reason
        self.code = code
        self.detail = detail
    }
}

public struct CertificateInfo: Sendable {
    public var host: String
    public var port: UInt16
    public var commonName: String
    public var subject: String
    public var issuer: String
    public var fingerprint: String
    /// A different certificate was accepted for this host before.
    public var changed: Bool
    public var previousFingerprint: String?

    public init(host: String, port: UInt16, commonName: String, subject: String, issuer: String,
                fingerprint: String, changed: Bool, previousFingerprint: String?) {
        self.host = host
        self.port = port
        self.commonName = commonName
        self.subject = subject
        self.issuer = issuer
        self.fingerprint = fingerprint
        self.changed = changed
        self.previousFingerprint = previousFingerprint
    }
}

public enum CertificateDecision: Sendable {
    case reject, acceptAlways, acceptOnce
}

public struct CredentialRequest: Sendable {
    /// The gateway asks, not the remote computer.
    public var gateway: Bool
    /// The server wants a user name with the password; some VNC servers only take a password.
    public var needsUsername: Bool
    public var username: String
    public var domain: String

    public init(gateway: Bool = false, needsUsername: Bool = true, username: String = "", domain: String = "") {
        self.gateway = gateway
        self.needsUsername = needsUsername
        self.username = username
        self.domain = domain
    }
}

public struct Credentials: Sendable {
    public var username: String
    public var password: String
    public var domain: String?

    public init(username: String, password: String, domain: String? = nil) {
        self.username = username
        self.password = password
        self.domain = domain
    }
}

/// A cursor image from the remote side: BGRA, premultiplied, in remote pixels.
public struct CursorImage: Sendable {
    public var id: UInt64
    public var bgra: Data
    public var width: Int
    public var height: Int
    public var hotspot: CGPoint

    public init(id: UInt64, bgra: Data, width: Int, height: Int, hotspot: CGPoint) {
        self.id = id
        self.bgra = bgra
        self.width = width
        self.height = height
        self.hotspot = hotspot
    }
}

public enum RemoteCursor: Equatable, Sendable {
    case system
    case hidden
    case custom(UInt64)
}

public enum MouseButton: Sendable {
    case left, right, middle, back, forward
}
