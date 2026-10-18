import AfarEngine
import Foundation
import IOSurface
import os

/// One RDP connection. Wraps an `AfarSession` from the C engine.
///
/// The engine runs on its own thread. Everything it reports reaches the delegate on the main
/// actor. The two questions it can ask (certificate and credentials) hold the engine thread
/// until the delegate answers, so a dialog can stay open as long as the user needs.
public final class RDPSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case disconnected(RDPError?)
    }

    public struct Parameters: Sendable {
        public struct GatewayParameters: Sendable {
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
        public var width: UInt32
        public var height: UInt32
        public var desktopScale: UInt32
        public var deviceScale: UInt32
        public var fullColor: Bool
        public var audio: Bool
        public var clipboard: Bool
        public var gateway: GatewayParameters?
        public var configDirectory: URL

        public init(host: String, port: UInt16 = 3389, username: String? = nil, domain: String? = nil,
                    password: String? = nil, width: UInt32, height: UInt32, desktopScale: UInt32 = 100,
                    deviceScale: UInt32 = 100, fullColor: Bool = true, audio: Bool = true, clipboard: Bool = true,
                    gateway: GatewayParameters? = nil, configDirectory: URL) {
            self.host = host
            self.port = port
            self.username = username
            self.domain = domain
            self.password = password
            self.width = width
            self.height = height
            self.desktopScale = desktopScale
            self.deviceScale = deviceScale
            self.fullColor = fullColor
            self.audio = audio
            self.clipboard = clipboard
            self.gateway = gateway
            self.configDirectory = configDirectory
        }
    }

    public weak var delegate: RDPSessionDelegate?
    public private(set) var state: State = .idle

    private var engine: OpaquePointer?
    /// The newest image not yet handed to the delegate. Frames arriving faster than the main
    /// thread takes them replace each other here, so at most one main-queue hop is pending.
    private let pendingFrame = OSAllocatedUnfairLock<IOSurface?>(uncheckedState: nil)
    /// Answers the engine is waiting for, so closing the session can release them.
    private let pendingAnswers = OSAllocatedUnfairLock(initialState: [DispatchSemaphore]())
    /// The engine reports a rejected certificate as a generic TLS failure; remember the cause.
    private let certificateRejected = OSAllocatedUnfairLock(initialState: false)

    public init() {
        _ = RDPSession.initializeEngine
    }

    private static let initializeEngine: Bool = afar_engine_initialize()

    deinit {
        close()
    }

    // MARK: Lifecycle

    public func connect(_ parameters: Parameters) throws {
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
            return RDPSession.from(ctx).engineVerifyCertificate(CertificateInfo(info.pointee)).engineValue
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
            RDPSession.from(ctx).onMain { $0.delegate?.session($0, cursorCreated: image) }
        }
        callbacks.cursorReleased = { ctx, id in
            RDPSession.from(ctx).onMain { $0.delegate?.session($0, cursorReleased: id) }
        }
        callbacks.cursorChanged = { ctx, kind, id in
            let cursor: RemoteCursor = switch kind {
            case AfarCursorHidden: .hidden
            case AfarCursorCustom: .custom(id)
            default: .system
            }
            RDPSession.from(ctx).onMain { $0.delegate?.session($0, cursorChanged: cursor) }
        }
        callbacks.displayControlReady = { ctx in
            RDPSession.from(ctx).onMain { $0.delegate?.sessionDisplayControlReady($0) }
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
            RDPSession.from(ctx).onMain { $0.delegate?.session($0, clipboardReceived: content) }
        }
        callbacks.clipboardFilesOffered = { ctx, count, bytes in
            RDPSession.from(ctx).onMain { $0.delegate?.session($0, remoteFilesOffered: Int(count), bytes: bytes) }
        }
        callbacks.clipboardFilesProgress = { ctx, done, total in
            RDPSession.from(ctx).onMain { $0.delegate?.session($0, remoteFilesProgress: done, of: total) }
        }
        callbacks.clipboardFilesFinished = { ctx, success in
            RDPSession.from(ctx).onMain { $0.delegate?.session($0, remoteFilesFinished: success) }
        }

        guard let engine = afar_session_new(&callbacks) else { throw RDPError.engineUnavailable }
        self.engine = engine

        try? FileManager.default.createDirectory(at: parameters.configDirectory, withIntermediateDirectories: true)

        // The engine copies every string into FreeRDP's settings before afar_session_connect returns.
        let strings = CStrings()
        defer { strings.release() }
        var params = AfarConnectParams()
        params.host = strings.add(parameters.host)
        params.port = parameters.port
        params.username = strings.add(parameters.username)
        params.domain = strings.add(parameters.domain)
        params.password = strings.add(parameters.password)
        params.configDirectory = strings.add(parameters.configDirectory.path)
        params.width = parameters.width
        params.height = parameters.height
        params.desktopScale = parameters.desktopScale
        params.deviceScale = parameters.deviceScale
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
        guard ok else { throw RDPError.invalidParameters }
        state = .connecting
    }

    /// Ends the connection. The delegate sees `.disconnected` once the engine has finished.
    public func disconnect() {
        releasePendingAnswers()
        if let engine { afar_session_disconnect(engine) }
    }

    /// Ends the connection and waits for the engine thread. Safe to call more than once.
    public func close() {
        guard let engine else { return }
        releasePendingAnswers()
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

    public func requestLayout(width: UInt32, height: UInt32, desktopScale: UInt32, deviceScale: UInt32) {
        if let engine { afar_session_request_layout(engine, width, height, desktopScale, deviceScale) }
    }

    /// Makes files and folders from this Mac available to the remote clipboard. Folders are walked
    /// in the background; contents are read from disk only when the remote side pastes.
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

    /// Downloads the files the remote side last offered (see the delegate) into `directory`.
    @discardableResult
    public func fetchRemoteFiles(into directory: URL) -> Bool {
        guard let engine else { return false }
        return directory.path.withCString { afar_session_fetch_remote_files(engine, $0) }
    }

    public func cancelRemoteFiles() {
        if let engine { afar_session_cancel_remote_files(engine) }
    }

    /// The session's counters now; `StatisticsSample` turns two readings into rates.
    public func statistics() -> RDPStatistics? {
        guard let engine else { return nil }
        var statistics = AfarStatistics()
        guard afar_session_get_statistics(engine, &statistics) else { return nil }
        return RDPStatistics(statistics, time: ProcessInfo.processInfo.systemUptime)
    }

    /// Makes this Mac's clipboard available to the remote computer; nil withdraws it.
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

    private func onMain(_ body: @escaping @MainActor (RDPSession) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { body(self) }
        }
    }

    private func engineStateChanged(_ state: AfarState, code: UInt32, message: String?) {
        let newState: State
        switch state {
        case AfarStateConnecting: newState = .connecting
        case AfarStateConnected: newState = .connected
        default:
            if certificateRejected.withLock({ $0 }) {
                newState = .disconnected(RDPError(reason: .certificate, code: code, detail: message))
            } else {
                newState = .disconnected(RDPError(code: code, message: message))
            }
        }
        onMain { session in
            session.state = newState
            session.delegate?.session(session, stateChanged: newState)
        }
    }

    private func engineSurfaceChanged(_ surface: IOSurfaceRef, width: UInt32, height: UInt32) {
        let surface = unsafeBitCast(surface, to: IOSurface.self)
        let size = PixelSize(width: Int(width), height: Int(height))
        onMain { $0.delegate?.session($0, surfaceChanged: surface, size: size) }
    }

    private func engineFrameUpdated(_ surface: IOSurfaceRef) {
        let surface = unsafeBitCast(surface, to: IOSurface.self)
        let alreadyPending = pendingFrame.withLockUnchecked { pending in
            defer { pending = surface }
            return pending != nil
        }
        guard !alreadyPending else { return }
        onMain { session in
            guard let frame = session.pendingFrame.withLockUnchecked({ pending in
                defer { pending = nil }
                return pending
            }) else { return }
            session.delegate?.session(session, frameUpdated: frame)
        }
    }

    /// Runs `ask` on the main actor and blocks this (engine) thread until it answers.
    private func waitForAnswer<T: Sendable>(default fallback: T,
                                            _ ask: @escaping @MainActor (RDPSession, @escaping @Sendable (T) -> Void) -> Void) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let answer = OSAllocatedUnfairLock(initialState: fallback)
        pendingAnswers.withLock { $0.append(semaphore) }
        onMain { session in
            ask(session) { value in
                answer.withLock { $0 = value }
                semaphore.signal()
            }
        }
        semaphore.wait()
        pendingAnswers.withLock { $0.removeAll { $0 === semaphore } }
        return answer.withLock { $0 }
    }

    private func releasePendingAnswers() {
        pendingAnswers.withLock { list in
            list.forEach { $0.signal() }
            list.removeAll()
        }
    }

    private func engineVerifyCertificate(_ info: CertificateInfo) -> CertificateDecision {
        let decision = waitForAnswer(default: CertificateDecision.reject) { session, answer in
            guard let delegate = session.delegate else { return answer(.reject) }
            delegate.session(session, verify: info, decide: answer)
        }
        if decision == .reject { certificateRejected.withLock { $0 = true } }
        return decision
    }

    private func engineAuthenticate(gateway: Bool, username: Buffer, password: Buffer, domain: Buffer) -> Bool {
        let request = CredentialRequest(gateway: gateway, username: username.string, domain: domain.string)
        let credentials: Credentials? = waitForAnswer(default: nil) { session, answer in
            guard let delegate = session.delegate else { return answer(nil) }
            delegate.session(session, credentialsFor: request, provide: answer)
        }
        guard let credentials else { return false }
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
