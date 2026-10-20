import AfarEngine
import Foundation
import IOSurface
import os

/// One RDP connection. Wraps an `AfarSession` from the C engine (FreeRDP).
public final class RDPSession: RemoteSession, @unchecked Sendable {
    public weak var delegate: RemoteSessionDelegate?
    public private(set) var state: SessionState = .idle

    private var engine: OpaquePointer?
    /// Set once in init, before any thread can use it.
    private var relay: SessionRelay<RDPSession>!
    /// The engine reports a rejected certificate as a generic TLS failure; remember the cause.
    private let certificateRejected = OSAllocatedUnfairLock(initialState: false)

    public init() {
        _ = RDPSession.initializeEngine
        relay = SessionRelay(self)
    }

    private static let initializeEngine: Bool = afar_engine_initialize()

    deinit {
        close()
    }

    // MARK: Lifecycle

    public func connect(_ parameters: SessionParameters) throws {
        precondition(engine == nil, "connect called twice")
        var callbacks = AfarCallbacks()
        callbacks.context = Unmanaged.passUnretained(self).toOpaque()
        callbacks.stateChanged = { ctx, state, code, message in
            RDPSession.from(ctx).engineStateChanged(state, code: code, message: message.map { String(cString: $0) })
        }
        callbacks.surfaceChanged = { ctx, surface, width, height in
            guard let surface else { return }
            RDPSession.from(ctx).engineSurfaceChanged(surface, width: width, height: height)
        }
        callbacks.frameUpdated = { ctx, surface in
            guard let surface else { return }
            RDPSession.from(ctx).engineFrameUpdated(surface)
        }
        callbacks.verifyCertificate = { ctx, info in
            guard let info else { return AfarCertificateReject }
            return RDPSession.from(ctx).engineVerifyCertificate(CertificateInfo(engine: info.pointee)).engineValue
        }
        callbacks.authenticate = { ctx, gateway, user, userSize, pass, passSize, domain, domainSize in
            guard let user, let pass, let domain else { return false }
            return RDPSession.from(ctx).engineAuthenticate(
                gateway: gateway,
                username: Buffer(user, userSize), password: Buffer(pass, passSize), domain: Buffer(domain, domainSize))
        }
        callbacks.cursorCreated = { ctx, id, bgra, width, height, hotX, hotY in
            guard let bgra else { return }
            let data = Data(bytes: bgra, count: Int(width) * Int(height) * 4)
            let image = CursorImage(id: id, bgra: data, width: Int(width), height: Int(height),
                                    hotspot: CGPoint(x: Int(hotX), y: Int(hotY)))
            RDPSession.from(ctx).relay.onMain { $0.delegate?.session($0, cursorCreated: image) }
        }
        callbacks.cursorReleased = { ctx, id in
            RDPSession.from(ctx).relay.onMain { $0.delegate?.session($0, cursorReleased: id) }
        }
        callbacks.cursorChanged = { ctx, kind, id in
            let cursor: RemoteCursor = switch kind {
            case AfarCursorHidden: .hidden
            case AfarCursorCustom: .custom(id)
            default: .system
            }
            RDPSession.from(ctx).relay.onMain { $0.delegate?.session($0, cursorChanged: cursor) }
        }
        callbacks.displayControlReady = { ctx in
            RDPSession.from(ctx).relay.onMain { $0.delegate?.sessionCanResize($0) }
        }
        callbacks.clipboardReceived = { ctx, kind, bytes, length in
            guard let bytes else { return }
            let data = Data(bytes: bytes, count: length)
            let content: ClipboardContent? = switch kind {
            case AfarClipboardText: .fromUTF16(data)
            case AfarClipboardPNG: .fromPNG(data)
            default: .fromDIB(data)
            }
            guard let content else { return }
            RDPSession.from(ctx).relay.onMain { $0.delegate?.session($0, clipboardReceived: content) }
        }
        callbacks.clipboardFilesOffered = { ctx, count, bytes in
            RDPSession.from(ctx).relay.onMain { $0.delegate?.session($0, remoteFilesOffered: Int(count), bytes: bytes) }
        }
        callbacks.clipboardFilesProgress = { ctx, done, total in
            RDPSession.from(ctx).relay.onMain { $0.delegate?.session($0, remoteFilesProgress: done, of: total) }
        }
        callbacks.clipboardFilesFinished = { ctx, success in
            RDPSession.from(ctx).relay.onMain { $0.delegate?.session($0, remoteFilesFinished: success) }
        }

        guard let engine = afar_session_new(&callbacks) else { throw SessionError.engineUnavailable }
        self.engine = engine

        try? FileManager.default.createDirectory(at: parameters.stateDirectory, withIntermediateDirectories: true)
        // The size agreed at connect time is capped; display control lifts the cap afterwards.
        let layout = parameters.layout.cappedForConnect

        // The engine copies every string into FreeRDP's settings before afar_session_connect returns.
        let strings = CStrings()
        defer { strings.release() }
        var params = AfarConnectParams()
        params.host = strings.add(parameters.host)
        params.port = parameters.port
        params.username = strings.add(parameters.username)
        params.domain = strings.add(parameters.domain)
        params.password = strings.add(parameters.password)
        params.configDirectory = strings.add(parameters.stateDirectory.path)
        params.width = layout.width
        params.height = layout.height
        params.desktopScale = layout.desktopScale
        params.deviceScale = layout.deviceScale
        params.fullColor = parameters.fullColor
        params.audio = parameters.audio
        params.clipboard = parameters.clipboard
        if let gateway = parameters.gateway {
            params.gatewayHost = strings.add(gateway.host)
            params.gatewayPort = gateway.port
            params.gatewayUsername = strings.add(gateway.username)
            params.gatewayDomain = strings.add(gateway.domain)
            params.gatewayPassword = strings.add(gateway.password)
        }
        let ok = afar_session_connect(engine, &params)
        guard ok else { throw SessionError.invalidParameters }
        state = .connecting
    }

    public func disconnect() {
        relay.releasePendingAnswers()
        if let engine { afar_session_disconnect(engine) }
    }

    public func close() {
        guard let engine else { return }
        relay.releasePendingAnswers()
        afar_session_free(engine)
        self.engine = nil
    }

    // MARK: Input (any thread)

    public func sendKey(_ macKeyCode: UInt16, down: Bool) {
        if let engine { afar_session_send_key(engine, macKeyCode, down) }
    }

    public func releaseAllInput() {
        if let engine { afar_session_release_all(engine) }
    }

    public func sendMouseMove(x: Int32, y: Int32) {
        if let engine { afar_session_send_mouse_move(engine, x, y) }
    }

    public func sendMouseButton(_ button: MouseButton, down: Bool, x: Int32, y: Int32) {
        if let engine { afar_session_send_mouse_button(engine, button.engineValue, down, x, y) }
    }

    /// Wheel deltas in RDP units: 120 per notch, positive is up / right.
    public func sendWheel(vertical: Int32, horizontal: Int32, x: Int32, y: Int32) {
        if let engine { afar_session_send_wheel(engine, vertical, horizontal, x, y) }
    }

    public func requestLayout(_ layout: DesktopLayout) {
        if let engine {
            afar_session_request_layout(engine, layout.width, layout.height, layout.desktopScale, layout.deviceScale)
        }
    }

    /// Folders are walked in the background; contents are read from disk only when the remote
    /// side pastes.
    public func offerFiles(_ urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = ClipboardFileList(urls).entries
            guard let self, let engine = self.engine, !entries.isEmpty else { return }
            let strings = CStrings()
            defer { strings.release() }
            let paths = entries.map { strings.add($0.url.path) }
            let names = entries.map { strings.add($0.name) }
            let directories = entries.map(\.isDirectory)
            let sizes = entries.map(\.size)
            paths.withUnsafeBufferPointer { paths in
                names.withUnsafeBufferPointer { names in
                    afar_session_offer_files(engine, paths.baseAddress, names.baseAddress, directories, sizes, entries.count)
                }
            }
        }
    }

    @discardableResult
    public func fetchRemoteFiles(into directory: URL) -> Bool {
        guard let engine else { return false }
        return directory.path.withCString { afar_session_fetch_remote_files(engine, $0) }
    }

    public func cancelRemoteFiles() {
        if let engine { afar_session_cancel_remote_files(engine) }
    }

    public func statistics() -> RemoteStatistics? {
        guard let engine else { return nil }
        var statistics = AfarStatistics()
        guard afar_session_get_statistics(engine, &statistics) else { return nil }
        return RemoteStatistics(statistics, time: ProcessInfo.processInfo.systemUptime)
    }

    public func offerClipboard(_ content: ClipboardContent?) {
        guard let engine else { return }
        let png = content?.pngData
        let dib = content?.dibData
        let text = content?.windowsText
        func offer(_ utf8: UnsafePointer<CChar>?) {
            png.withUnsafeBytesIfPresent { pngBytes, pngCount in
                dib.withUnsafeBytesIfPresent { dibBytes, dibCount in
                    afar_session_offer_clipboard(engine, utf8, pngBytes, pngCount, dibBytes, dibCount)
                }
            }
        }
        if let text { text.withCString(offer) } else { offer(nil) }
    }

    // MARK: Engine callbacks (session thread)

    private static func from(_ context: UnsafeMutableRawPointer?) -> RDPSession {
        Unmanaged<RDPSession>.fromOpaque(context!).takeUnretainedValue()
    }

    private func engineStateChanged(_ state: AfarState, code: UInt32, message: String?) {
        let newState: SessionState
        switch state {
        case AfarStateConnecting: newState = .connecting
        case AfarStateConnected: newState = .connected
        default:
            if certificateRejected.withLock({ $0 }) {
                newState = .disconnected(SessionError(reason: .certificate, code: code, detail: message))
            } else {
                newState = .disconnected(SessionError(rdpCode: code, message: message))
            }
        }
        relay.onMain { session in
            session.state = newState
            session.delegate?.session(session, stateChanged: newState)
        }
    }

    private func engineSurfaceChanged(_ surface: IOSurfaceRef, width: UInt32, height: UInt32) {
        let surface = unsafeBitCast(surface, to: IOSurface.self)
        let size = PixelSize(width: Int(width), height: Int(height))
        relay.onMain { $0.delegate?.session($0, surfaceChanged: surface, size: size) }
    }

    private func engineFrameUpdated(_ surface: IOSurfaceRef) {
        relay.frameUpdated(unsafeBitCast(surface, to: IOSurface.self))
    }

    private func engineVerifyCertificate(_ info: CertificateInfo) -> CertificateDecision {
        let decision = relay.verifyCertificate(info)
        if decision == .reject { certificateRejected.withLock { $0 = true } }
        return decision
    }

    private func engineAuthenticate(gateway: Bool, username: Buffer, password: Buffer, domain: Buffer) -> Bool {
        let request = CredentialRequest(gateway: gateway, username: username.string, domain: domain.string)
        guard let credentials = relay.credentials(for: request) else { return false }
        username.store(credentials.username)
        password.store(credentials.password)
        domain.store(credentials.domain ?? "")
        return true
    }
}

/// C copies of Swift strings that live until `release`, which wipes them (some are passwords).
private final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func add(_ string: String?) -> UnsafePointer<CChar>? {
        guard let string, let copy = strdup(string) else { return nil }
        pointers.append(copy)
        return UnsafePointer(copy)
    }

    func release() {
        for pointer in pointers {
            memset_s(pointer, strlen(pointer), 0, strlen(pointer))
            free(pointer)
        }
        pointers.removeAll()
    }
}

private extension Optional where Wrapped == Data {
    func withUnsafeBytesIfPresent<R>(_ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
        guard let data = self, !data.isEmpty else { return body(nil, 0) }
        return data.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress, data.count) }
    }
}

/// A fixed-size C string buffer handed over by the engine.
private struct Buffer {
    let pointer: UnsafeMutablePointer<CChar>
    let size: Int

    init(_ pointer: UnsafeMutablePointer<CChar>, _ size: Int) {
        self.pointer = pointer
        self.size = size
    }

    var string: String { String(cString: pointer) }

    func store(_ value: String) {
        let bytes = Array(value.utf8.prefix(size - 1))
        pointer.withMemoryRebound(to: UInt8.self, capacity: size) { target in
            for (index, byte) in bytes.enumerated() { target[index] = byte }
            target[bytes.count] = 0
        }
    }
}

// MARK: - Engine values

extension SessionError {
    static let engineUnavailable = SessionError(reason: .other, detail: "The RDP engine could not start.")
    static let invalidParameters = SessionError(reason: .other, detail: "The connection settings were rejected.")

    /// From FreeRDP's error code; `nil` when it describes a normal end of the session.
    init?(rdpCode code: UInt32, message: String?) {
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

private extension CertificateInfo {
    init(engine info: AfarCertificateInfo) {
        func string(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
        self.init(host: string(info.host), port: info.port, commonName: string(info.commonName),
                  subject: string(info.subject), issuer: string(info.issuer), fingerprint: string(info.fingerprint),
                  changed: info.changed, previousFingerprint: info.oldFingerprint.map { String(cString: $0) })
    }
}

private extension CertificateDecision {
    var engineValue: AfarCertificateDecision {
        switch self {
        case .reject: AfarCertificateReject
        case .acceptAlways: AfarCertificateAcceptAlways
        case .acceptOnce: AfarCertificateAcceptOnce
        }
    }
}

private extension MouseButton {
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
