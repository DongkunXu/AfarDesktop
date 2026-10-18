import AfarEngine
import CoreGraphics
import Foundation
import IOSurface

/// Receives everything a session reports. Called on the main actor.
@MainActor
public protocol RDPSessionDelegate: AnyObject {
    func session(_ session: RDPSession, stateChanged state: RDPSession.State)
    func session(_ session: RDPSession, surfaceChanged surface: IOSurface, size: PixelSize)
    /// A new image of the desktop, in one of the surfaces the engine rotates through.
    func session(_ session: RDPSession, frameUpdated surface: IOSurface)
    func sessionDisplayControlReady(_ session: RDPSession)

    /// The engine waits until `decide` is called.
    func session(_ session: RDPSession, verify certificate: CertificateInfo,
                 decide: @escaping @Sendable (CertificateDecision) -> Void)
    /// The engine waits until `provide` is called; `nil` cancels the connection.
    func session(_ session: RDPSession, credentialsFor request: CredentialRequest,
                 provide: @escaping @Sendable (Credentials?) -> Void)

    func session(_ session: RDPSession, cursorCreated cursor: CursorImage)
    func session(_ session: RDPSession, cursorReleased id: UInt64)
    func session(_ session: RDPSession, cursorChanged cursor: RemoteCursor)

    /// Something was copied on the remote computer.
    func session(_ session: RDPSession, clipboardReceived content: ClipboardContent)

    /// Files were copied on the remote computer; `fetchRemoteFiles(into:)` downloads them.
    func session(_ session: RDPSession, remoteFilesOffered count: Int, bytes: UInt64)
    func session(_ session: RDPSession, remoteFilesProgress done: UInt64, of total: UInt64)
    func session(_ session: RDPSession, remoteFilesFinished success: Bool)
}

public struct PixelSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct RDPError: Error, Equatable, Sendable {
    public enum Reason: Sendable {
        case authentication, certificate, hostNotFound, unreachable, replaced, timeout
        case serverDenied, networkLost, other
    }

    public var reason: Reason
    /// FreeRDP's error code and its own description, for diagnostics.
    public var code: UInt32
    public var detail: String?

    static let engineUnavailable = RDPError(reason: .other, code: 0, detail: "The RDP engine could not start.")
    static let invalidParameters = RDPError(reason: .other, code: 0, detail: "The connection settings were rejected.")

    init(reason: Reason, code: UInt32, detail: String?) {
        self.reason = reason
        self.code = code
        self.detail = detail
    }

    /// `nil` when the code describes a normal end of the session.
    init?(code: UInt32, message: String?) {
        let reason: Reason
        switch afar_end_reason(code) {
        case AfarEndedNormally: return nil
        case AfarEndedAuthentication: reason = .authentication
        case AfarEndedCertificate: reason = .certificate
        case AfarEndedHostNotFound: reason = .hostNotFound
        case AfarEndedUnreachable: reason = .unreachable
        case AfarEndedReplaced: reason = .replaced
        case AfarEndedTimeout: reason = .timeout
        case AfarEndedServerDenied: reason = .serverDenied
        case AfarEndedNetworkLost: reason = .networkLost
        default: reason = .other
        }
        self.init(reason: reason, code: code, detail: message)
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

    init(_ info: AfarCertificateInfo) {
        func string(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
        host = string(info.host)
        port = info.port
        commonName = string(info.commonName)
        subject = string(info.subject)
        issuer = string(info.issuer)
        fingerprint = string(info.fingerprint)
        changed = info.changed
        previousFingerprint = info.oldFingerprint.map { String(cString: $0) }
    }
}

public enum CertificateDecision: Sendable {
    case reject, acceptAlways, acceptOnce

    var engineValue: AfarCertificateDecision {
        switch self {
        case .reject: AfarCertificateReject
        case .acceptAlways: AfarCertificateAcceptAlways
        case .acceptOnce: AfarCertificateAcceptOnce
        }
    }
}

public struct CredentialRequest: Sendable {
    /// The gateway asks, not the remote computer.
    public var gateway: Bool
    public var username: String
    public var domain: String
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
}

public enum RemoteCursor: Equatable, Sendable {
    case system
    case hidden
    case custom(UInt64)
}

public enum MouseButton: Sendable {
    case left, right, middle, back, forward

    var engineValue: AfarMouseButton {
        switch self {
        case .left: AfarMouseLeft
        case .right: AfarMouseRight
        case .middle: AfarMouseMiddle
        case .back: AfarMouseBack
        case .forward: AfarMouseForward
        }
    }
}
