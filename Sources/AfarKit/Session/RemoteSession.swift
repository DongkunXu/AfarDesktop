import Foundation
import IOSurface

/// One connection to a remote computer, whatever the protocol. `RDPSession` and `VNCSession`
/// implement it; the app talks to this interface only.
///
/// A session works on its own thread. Everything it reports reaches the delegate on the main
/// actor, and the questions it can ask (certificate, credentials) hold that thread until the
/// delegate answers. Input and the other calls may come from any thread.
public protocol RemoteSession: AnyObject, Sendable {
    var delegate: RemoteSessionDelegate? { get set }
    /// Updated on the main actor, just before the delegate hears of the change.
    var state: SessionState { get }

    func connect(_ parameters: SessionParameters) throws
    /// Ends the connection. The delegate sees `.disconnected` once the session has finished.
    func disconnect()
    /// Ends the connection and waits for the session thread. Safe to call more than once.
    func close()

    /// Keyboard: macOS virtual key codes (NSEvent.keyCode).
    func sendKey(_ macKeyCode: UInt16, down: Bool)
    /// Releases every key and button the remote side still considers pressed.
    func releaseAllInput()
    /// Mouse positions in remote desktop pixels.
    func sendMouseMove(x: Int32, y: Int32)
    func sendMouseButton(_ button: MouseButton, down: Bool, x: Int32, y: Int32)
    /// Wheel deltas in RDP units: 120 per notch, positive is up / right.
    func sendWheel(vertical: Int32, horizontal: Int32, x: Int32, y: Int32)

    /// Asks the remote side for a new desktop size; ignored where the server cannot resize.
    func requestLayout(_ layout: DesktopLayout)

    /// Makes this Mac's clipboard available to the remote computer; nil withdraws it.
    func offerClipboard(_ content: ClipboardContent?)
    /// Makes files from this Mac available to the remote clipboard, where the protocol can.
    func offerFiles(_ urls: [URL])
    /// Downloads the files the remote side last offered (see the delegate) into `directory`.
    @discardableResult
    func fetchRemoteFiles(into directory: URL) -> Bool
    func cancelRemoteFiles()

    /// The session's counters now; `StatisticsSample` turns two readings into rates.
    func statistics() -> RemoteStatistics?
}

extension RemoteProtocol {
    /// A new, unconnected session for this protocol.
    public func makeSession() -> any RemoteSession {
        switch self {
        case .rdp: RDPSession()
        case .vnc: VNCSession()
        }
    }
}

public enum SessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected(SessionError?)
}

/// Everything needed to connect. Fields a protocol has no use for are ignored (VNC has no
/// domain, gateway, audio or interface scale).
public struct SessionParameters: Sendable {
    public struct Gateway: Sendable {
        public var host: String
        public var port: UInt16
        /// nil: sign in to the gateway with the computer's credentials.
        public var username: String?
        public var domain: String?
        public var password: String?

        public init(host: String, port: UInt16 = 443, username: String? = nil, domain: String? = nil,
                    password: String? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.domain = domain
            self.password = password
        }
    }

    public var host: String
    public var port: UInt16
    public var username: String?
    public var domain: String?
    public var password: String?
    /// The desktop size to start with.
    public var layout: DesktopLayout
    /// Full colour detail: H.264 4:4:4 for RDP, lossless encodings for VNC.
    public var fullColor: Bool
    public var audio: Bool
    public var clipboard: Bool
    public var gateway: Gateway?
    /// Where the session keeps its own state, such as the certificates the user accepted.
    public var stateDirectory: URL

    public init(host: String, port: UInt16, username: String? = nil, domain: String? = nil,
                password: String? = nil, layout: DesktopLayout, fullColor: Bool = true, audio: Bool = true,
                clipboard: Bool = true, gateway: Gateway? = nil, stateDirectory: URL) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.password = password
        self.layout = layout
        self.fullColor = fullColor
        self.audio = audio
        self.clipboard = clipboard
        self.gateway = gateway
        self.stateDirectory = stateDirectory
    }
}

/// Receives everything a session reports. Called on the main actor.
@MainActor
public protocol RemoteSessionDelegate: AnyObject {
    func session(_ session: any RemoteSession, stateChanged state: SessionState)
    func session(_ session: any RemoteSession, surfaceChanged surface: IOSurface, size: PixelSize)
    /// A new image of the desktop, in one of the surfaces the session rotates through.
    func session(_ session: any RemoteSession, frameUpdated surface: IOSurface)
    /// The server accepts desktop size changes from now on.
    func sessionCanResize(_ session: any RemoteSession)

    /// The session waits until `decide` is called.
    func session(_ session: any RemoteSession, verify certificate: CertificateInfo,
                 decide: @escaping @Sendable (CertificateDecision) -> Void)
    /// The session waits until `provide` is called; `nil` cancels the connection.
    func session(_ session: any RemoteSession, credentialsFor request: CredentialRequest,
                 provide: @escaping @Sendable (Credentials?) -> Void)

    func session(_ session: any RemoteSession, cursorCreated cursor: CursorImage)
    func session(_ session: any RemoteSession, cursorReleased id: UInt64)
    func session(_ session: any RemoteSession, cursorChanged cursor: RemoteCursor)

    /// Something was copied on the remote computer.
    func session(_ session: any RemoteSession, clipboardReceived content: ClipboardContent)

    /// Files were copied on the remote computer; `fetchRemoteFiles(into:)` downloads them.
    func session(_ session: any RemoteSession, remoteFilesOffered count: Int, bytes: UInt64)
    func session(_ session: any RemoteSession, remoteFilesProgress done: UInt64, of total: UInt64)
    func session(_ session: any RemoteSession, remoteFilesFinished success: Bool)
}
