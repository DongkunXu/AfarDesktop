import AfarEngine
import Foundation
import IOSurface
import os

/// One VNC (RFB 3.3 to 3.8) connection.
///
/// The session thread connects, authenticates (see `VNCSecurity`) and then reads server
/// messages; the framebuffer and decoders belong to it alone. Input from the app is turned into
/// messages on the caller's thread and queued on the stream, which the session thread sends.
///
/// Images: Tight (with JPEG when colour detail may be reduced), ZRLE, Hextile, CopyRect, Raw.
/// The desktop follows the window where the server can resize (ExtendedDesktopSize); the cursor
/// is drawn by this Mac; the clipboard carries text, as Unicode where the server supports the
/// extended clipboard.
public final class VNCSession: RemoteSession, @unchecked Sendable {
    public weak var delegate: RemoteSessionDelegate?
    public private(set) var state: SessionState = .idle

    /// Set once in init, before any thread can use it.
    private var relay: SessionRelay<VNCSession>!
    private let stream = VNCStream()
    private var parameters: SessionParameters?
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    /// The user ended the session; how it ends is then no error.
    private let ending = OSAllocatedUnfairLock(initialState: false)

    /// What the app's threads share with the session thread.
    private struct Shared {
        var connected = false
        var width = 0, height = 0
        var canResize = false
        var screen: (id: UInt32, flags: UInt32) = (0, 0)
        var requestedSize: (Int, Int)?
        var qemuKeys = false
        var extendedClipboard = false
        var localText: String?
        var buttons: UInt8 = 0
        var pointer: (UInt16, UInt16) = (0, 0)
        var pressed: [UInt16: UInt32] = [:] // mac key code → keysym sent with its press
        var wheel: (vertical: Int32, horizontal: Int32) = (0, 0)
        // Statistics.
        var frames: UInt64 = 0
        var decodeNanoseconds: UInt64 = 0
        var codecUse: [VideoCodec: Int] = [:]
    }

    private let shared = OSAllocatedUnfairLock(uncheckedState: Shared())

    // Session thread only.
    private var framebuffer: VNCFramebuffer?
    private let decoder = VNCDecoder()
    private var cursorId: UInt64 = 0

    public init() {
        relay = SessionRelay(self)
    }

    deinit {
        stream.cancel()
    }

    // MARK: Lifecycle

    public func connect(_ parameters: SessionParameters) throws {
        precondition(thread == nil, "connect called twice")
        self.parameters = parameters
        let thread = Thread { [self] in run(parameters) }
        thread.name = "VNC \(parameters.host)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        state = .connecting
        thread.start()
    }

    public func disconnect() {
        ending.withLock { $0 = true }
        relay.releasePendingAnswers()
        stream.cancel()
    }

    public func close() {
        guard thread != nil else { return }
        disconnect()
        finished.wait()
        finished.signal() // later calls return at once
    }

    private func run(_ parameters: SessionParameters) {
        relay.onMain { session in
            session.state = .connecting
            session.delegate?.session(session, stateChanged: .connecting)
        }
        var outcome: SessionError?
        do {
            try stream.connect(host: parameters.host, port: parameters.port, timeout: .seconds(15))
            try handshake(parameters)
            relay.onMain { session in
                session.state = .connected
                session.delegate?.session(session, stateChanged: .connected)
            }
            try receive()
        } catch {
            outcome = ending.withLock({ $0 }) ? nil : Self.sessionError(error)
        }
        shared.withLockUnchecked { $0.connected = false }
        relay.onMain { session in
            session.state = .disconnected(outcome)
            session.delegate?.session(session, stateChanged: .disconnected(outcome))
        }
        finished.signal()
    }

    private static func sessionError(_ error: Error) -> SessionError? {
        guard let error = error as? VNCError else { return SessionError(reason: .other, detail: "\(error)") }
        switch error {
        case .stream(let status):
            switch status {
            case AfarStreamHostNotFound: return SessionError(reason: .hostNotFound)
            case AfarStreamRefused, AfarStreamTimeout: return SessionError(reason: .unreachable)
            case AfarStreamTLSFailed: return SessionError(reason: .unreachable, detail: "TLS handshake failed")
            case AfarStreamCancelled: return nil
            default: return SessionError(reason: .networkLost)
            }
        case .protocolError(let detail): return SessionError(reason: .other, detail: detail)
        case .unsupported(let detail): return SessionError(reason: .unsupported, detail: detail)
        case .authentication(let detail): return SessionError(reason: .authentication, detail: detail)
        case .refused(let detail): return SessionError(reason: .serverDenied, detail: detail)
        case .certificateRejected: return SessionError(reason: .certificate)
        case .cancelled: return nil
        }
    }

    // MARK: Handshake

    private func handshake(_ parameters: SessionParameters) throws {
        // "RFB 003.008\n"; Apple says 003.889, which speaks 3.8.
        let version = String(decoding: try stream.bytes(12), as: UTF8.self)
        guard version.hasPrefix("RFB "), let serverMinor = Int(version.dropFirst(8).prefix(3)),
              version.dropFirst(4).prefix(3) == "003" else {
            throw VNCError.protocolError("not a VNC server")
        }
        let minor = serverMinor >= 8 ? 8 : (serverMinor >= 7 ? 7 : 3)
        stream.write(Array(String(format: "RFB 003.%03d\n", minor).utf8))

        var asked = false
        let security = VNCSecurity(
            stream: stream, host: parameters.host, port: parameters.port, minor: minor,
            credentials: { [self] needsUsername in
                // The saved password first; afterwards, ask.
                if !asked, let password = parameters.password, !needsUsername || !(parameters.username ?? "").isEmpty {
                    asked = true
                    return Credentials(username: parameters.username ?? "", password: password)
                }
                asked = true
                let request = CredentialRequest(needsUsername: needsUsername, username: parameters.username ?? "")
                guard let credentials = relay.credentials(for: request) else { throw VNCError.cancelled }
                return credentials
            },
            trust: { [self] peer in try trust(peer, parameters) })
        try security.negotiate()

        stream.write([1]) // ClientInit: share the desktop with other viewers
        let width = Int(try stream.u16()), height = Int(try stream.u16())
        try stream.skip(16) // the server's pixel format; ours follows
        _ = try stream.string(maximum: 1 << 16) // desktop name

        stream.write(Self.pixelFormatMessage())
        stream.write(Self.encodingsMessage(fullColor: parameters.fullColor, clipboard: parameters.clipboard))
        try resize(to: width, height)
        shared.withLockUnchecked { $0.connected = true }
    }

    /// 32 bits per pixel, depth 24, little-endian, red/green/blue in bits 16/8/0: BGRA in memory.
    private static func pixelFormatMessage() -> [UInt8] {
        var message = VNCMessage(0)
        message.padding(3)
        message.append([32, 24, 0, 1])
        message.u16(255); message.u16(255); message.u16(255)
        message.append([16, 8, 0])
        message.padding(3)
        return message.bytes
    }

    /// Lossless encodings first for full colour; Tight with JPEG first otherwise.
    static func encodings(fullColor: Bool, clipboard: Bool) -> [Int32] {
        var list: [VNCEncoding] = fullColor
            ? [.zrle, .tight, .hextile, .copyRect, .raw]
            : [.tight, .zrle, .hextile, .copyRect, .raw]
        list += [.extendedDesktopSize, .desktopSize, .lastRect, .cursor, .desktopName, .qemuExtendedKeyEvent]
        if clipboard { list.append(.extendedClipboard) }
        var values = list.map(\.rawValue)
        values.append(VNCEncoding.compressLevel(2))
        if !fullColor { values.append(VNCEncoding.jpegQuality(8)) }
        return values
    }

    private static func encodingsMessage(fullColor: Bool, clipboard: Bool) -> [UInt8] {
        let values = encodings(fullColor: fullColor, clipboard: clipboard)
        var message = VNCMessage(2)
        message.padding(1)
        message.u16(UInt16(values.count))
        values.forEach { message.s32($0) }
        return message.bytes
    }

    private func requestUpdate(incremental: Bool) {
        let (width, height) = shared.withLockUnchecked { ($0.width, $0.height) }
        var message = VNCMessage(3)
        message.u8(incremental ? 1 : 0)
        message.u16(0); message.u16(0)
        message.u16(UInt16(clamping: width)); message.u16(UInt16(clamping: height))
        stream.write(message.bytes)
    }

    private func trust(_ peer: AfarPeerCertificate, _ parameters: SessionParameters) throws {
        var peer = peer
        let fingerprint = withUnsafeBytes(of: &peer.fingerprint) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let store = VNCTrustStore(directory: parameters.stateDirectory)
        let known = store.fingerprint(host: parameters.host, port: parameters.port)
        guard known != fingerprint else { return }
        func text<T>(_ field: inout T) -> String {
            withUnsafeBytes(of: &field) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        let info = CertificateInfo(host: parameters.host, port: parameters.port, commonName: text(&peer.commonName),
                                   subject: text(&peer.subject), issuer: text(&peer.issuer), fingerprint: fingerprint,
                                   changed: known != nil, previousFingerprint: known)
        switch relay.verifyCertificate(info) {
        case .acceptAlways: store.accept(fingerprint, host: parameters.host, port: parameters.port)
        case .acceptOnce: break
        case .reject: throw VNCError.certificateRejected
        }
    }

    // MARK: Server messages

    private func receive() throws {
        requestUpdate(incremental: false)
        while true {
            switch try stream.u8() {
            case 0: try framebufferUpdate()
            case 1: // colour map entries (unused with true colour)
                try stream.skip(3)
                try stream.skip(Int(try stream.u16()) * 6)
            case 2: break // bell
            case 3: try serverCutText()
            case 150: break // end of continuous updates
            case 248: // fence
                try stream.skip(3 + 4)
                try stream.skip(Int(try stream.u8()))
            case let type:
                throw VNCError.protocolError("server message \(type)")
            }
        }
    }

    private func framebufferUpdate() throws {
        try stream.skip(1)
        let count = Int(try stream.u16())
        // Ask for the next update now, so it is on its way while this one is decoded.
        requestUpdate(incremental: true)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), waitedBefore = stream.waitNanoseconds

        var index = 0
        while count == 0xFFFF || index < count { // 0xFFFF: until LastRect
            index += 1
            let x = Int(try stream.u16()), y = Int(try stream.u16())
            let w = Int(try stream.u16()), h = Int(try stream.u16())
            let raw = try stream.s32()
            guard let encoding = VNCEncoding(rawValue: raw) else {
                throw VNCError.protocolError("encoding \(raw)")
            }
            switch encoding {
            case .lastRect:
                index = count == 0xFFFF ? Int.max : count
            case .desktopSize:
                try resize(to: w, h)
                requestUpdate(incremental: false)
            case .extendedDesktopSize:
                try extendedDesktopSize(reason: x, status: y, w: w, h: h)
            case .cursor:
                try cursor(hotX: x, hotY: y, w: w, h: h)
            case .desktopName:
                _ = try stream.string(maximum: 1 << 16)
            case .qemuExtendedKeyEvent:
                shared.withLockUnchecked { $0.qemuKeys = true }
            case .raw, .copyRect, .hextile, .zrle, .tight:
                guard let framebuffer else { throw VNCError.protocolError("pixels before the desktop size") }
                try decoder.decode(encoding, x: x, y: y, w: w, h: h, from: stream, into: framebuffer)
            case .extendedClipboard:
                throw VNCError.protocolError("unexpected clipboard rectangle")
            }
            if index == Int.max { break }
        }

        guard let framebuffer, framebuffer.hasChanges else { return }
        relay.frameUpdated(framebuffer.present())
        let decode = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start - (stream.waitNanoseconds - waitedBefore)
        let codec = decoder.lastCodec
        shared.withLockUnchecked { state in
            state.frames += 1
            state.decodeNanoseconds += decode
            if let codec { state.codecUse[codec, default: 0] += 1 }
        }
    }

    private func resize(to width: Int, _ height: Int) throws {
        guard let framebuffer = VNCFramebuffer(width: width, height: height) else {
            throw VNCError.protocolError("desktop size \(width)×\(height)")
        }
        self.framebuffer = framebuffer
        shared.withLockUnchecked {
            $0.width = width
            $0.height = height
        }
        let surface = framebuffer.present()
        let size = PixelSize(width: width, height: height)
        relay.onMain { $0.delegate?.session($0, surfaceChanged: surface, size: size) }
    }

    /// The server's screens, and whether it accepts size changes. `reason` 1 answers our request.
    private func extendedDesktopSize(reason: Int, status: Int, w: Int, h: Int) throws {
        let screens = Int(try stream.u8())
        try stream.skip(3)
        var first: (UInt32, UInt32)?
        for _ in 0..<screens {
            let id = try stream.u32()
            try stream.skip(8)
            let flags = try stream.u32()
            if first == nil { first = (id, flags) }
        }
        let announcesSupport = shared.withLockUnchecked { state -> Bool in
            defer {
                state.canResize = true
                if let first { state.screen = first }
            }
            return !state.canResize
        }
        if announcesSupport { relay.onMain { $0.delegate?.sessionCanResize($0) } }
        if reason == 1 && status != 0 { return } // the server declined our size; nothing changes
        if framebuffer?.width != w || framebuffer?.height != h {
            try resize(to: w, h)
            requestUpdate(incremental: false)
        }
    }

    /// The pointer image: pixels, then a bit mask of which are visible.
    private func cursor(hotX: Int, hotY: Int, w: Int, h: Int) throws {
        let pixels = try stream.bytes(w * h * 4)
        let maskRow = (w + 7) / 8
        let mask = try stream.bytes(maskRow * h)
        let previous = cursorId
        guard w > 0, h > 0 else {
            relay.onMain { $0.delegate?.session($0, cursorChanged: .hidden) }
            return
        }
        var bgra = Data(count: w * h * 4)
        bgra.withUnsafeMutableBytes { target in
            for y in 0..<h {
                for x in 0..<w where mask[y * maskRow + x / 8] & (0x80 >> (x % 8)) != 0 {
                    let i = (y * w + x) * 4
                    target[i] = pixels[i]; target[i + 1] = pixels[i + 1]; target[i + 2] = pixels[i + 2]
                    target[i + 3] = 0xFF
                }
            }
        }
        cursorId += 1
        let image = CursorImage(id: cursorId, bgra: bgra, width: w, height: h,
                                hotspot: CGPoint(x: min(hotX, w - 1), y: min(hotY, h - 1)))
        relay.onMain { session in
            session.delegate?.session(session, cursorCreated: image)
            session.delegate?.session(session, cursorChanged: .custom(image.id))
            if previous != 0 { session.delegate?.session(session, cursorReleased: previous) }
        }
    }

    private func serverCutText() throws {
        try stream.skip(3)
        let length = try stream.s32()
        guard length >= 0 else {
            guard -Int(length) <= VNCClipboard.maximumText else { throw VNCError.protocolError("clipboard message too large") }
            try extendedClipboard(VNCClipboard.parse(try stream.bytes(-Int(length))))
            return
        }
        guard Int(length) <= VNCClipboard.maximumText else { throw VNCError.protocolError("clipboard text too large") }
        let latin1 = try stream.bytes(Int(length))
        guard parameters?.clipboard == true else { return }
        let text = String(latin1.map { Character(Unicode.Scalar($0)) })
        relay.onMain { $0.delegate?.session($0, clipboardReceived: .text(text)) }
    }

    private func extendedClipboard(_ message: VNCClipboard.Message) throws {
        guard parameters?.clipboard == true else { return }
        switch message {
        case .caps:
            let hasText = shared.withLockUnchecked { state -> Bool in
                state.extendedClipboard = true
                return state.localText != nil
            }
            stream.write(VNCClipboard.clientMessage(VNCClipboard.caps()))
            // Text offered before the server said it speaks the extended clipboard.
            if hasText {
                stream.write(VNCClipboard.clientMessage(VNCClipboard.flagsOnly(.notify, formats: VNCClipboard.textFormat)))
            }
        case .notify(let formats):
            if formats & VNCClipboard.textFormat != 0 {
                stream.write(VNCClipboard.clientMessage(VNCClipboard.flagsOnly(.request, formats: VNCClipboard.textFormat)))
            }
        case .request(let formats):
            if formats & VNCClipboard.textFormat != 0, let text = shared.withLockUnchecked({ $0.localText }) {
                stream.write(VNCClipboard.clientMessage(VNCClipboard.provide(text)))
            }
        case .peek:
            let hasText = shared.withLockUnchecked { $0.localText != nil }
            stream.write(VNCClipboard.clientMessage(VNCClipboard.flagsOnly(.notify, formats: hasText ? VNCClipboard.textFormat : 0)))
        case .provide(let text):
            if let text { relay.onMain { $0.delegate?.session($0, clipboardReceived: .text(text)) } }
        }
    }

    // MARK: Input

    public func sendKey(_ macKeyCode: UInt16, down: Bool) {
        let message: [UInt8]? = shared.withLockUnchecked { state in
            guard state.connected else { return nil }
            let keysym: UInt32
            if down {
                guard let key = VNCKeymap.key(for: macKeyCode) else { return nil }
                let shift = state.pressed.keys.contains { VNCKeymap.shiftKeys.contains($0) }
                keysym = shift && key.shifted != 0 ? key.shifted : key.keysym
                state.pressed[macKeyCode] = keysym
            } else {
                guard let sent = state.pressed.removeValue(forKey: macKeyCode) else { return nil }
                keysym = sent
            }
            return Self.keyMessage(keysym: keysym, scancode: state.qemuKeys ? VNCKeymap.scancode(for: macKeyCode) : 0, down: down)
        }
        if let message { stream.write(message) }
    }

    /// A QEMU extended key event when the server takes scancodes, a plain key event otherwise.
    private static func keyMessage(keysym: UInt32, scancode: UInt32, down: Bool) -> [UInt8] {
        if scancode != 0 {
            var message = VNCMessage(255)
            message.u8(0)
            message.u16(down ? 1 : 0)
            message.u32(keysym)
            message.u32(scancode)
            return message.bytes
        }
        var message = VNCMessage(4)
        message.u8(down ? 1 : 0)
        message.padding(2)
        message.u32(keysym)
        return message.bytes
    }

    public func releaseAllInput() {
        let messages: [UInt8] = shared.withLockUnchecked { state in
            guard state.connected else { return [] }
            var bytes: [UInt8] = []
            for (code, keysym) in state.pressed {
                bytes += Self.keyMessage(keysym: keysym, scancode: state.qemuKeys ? VNCKeymap.scancode(for: code) : 0, down: false)
            }
            state.pressed.removeAll()
            state.buttons = 0
            bytes += Self.pointerMessage(0, state.pointer)
            return bytes
        }
        if !messages.isEmpty { stream.write(messages) }
    }

    private static func pointerMessage(_ buttons: UInt8, _ position: (UInt16, UInt16)) -> [UInt8] {
        var message = VNCMessage(5)
        message.u8(buttons)
        message.u16(position.0)
        message.u16(position.1)
        return message.bytes
    }

    private func pointer(x: Int32, y: Int32, _ change: (inout Shared) -> [UInt8]) {
        let bytes: [UInt8] = shared.withLockUnchecked { state in
            guard state.connected else { return [] }
            state.pointer = (UInt16(clamping: min(max(0, Int(x)), max(0, state.width - 1))),
                             UInt16(clamping: min(max(0, Int(y)), max(0, state.height - 1))))
            return change(&state)
        }
        if !bytes.isEmpty { stream.write(bytes) }
    }

    public func sendMouseMove(x: Int32, y: Int32) {
        pointer(x: x, y: y) { Self.pointerMessage($0.buttons, $0.pointer) }
    }

    public func sendMouseButton(_ button: MouseButton, down: Bool, x: Int32, y: Int32) {
        // Bits 0-2: left, middle, right; bit 7: back. Forward has no bit in classic RFB.
        let bit: UInt8 = switch button {
        case .left: 1
        case .middle: 2
        case .right: 4
        case .back: 128
        case .forward: 0
        }
        guard bit != 0 else { return }
        pointer(x: x, y: y) { state in
            if down { state.buttons |= bit } else { state.buttons &= ~bit }
            return Self.pointerMessage(state.buttons, state.pointer)
        }
    }

    /// VNC wheels move in clicks (buttons 4-7 pressed and released); 120 RDP units make one.
    public func sendWheel(vertical: Int32, horizontal: Int32, x: Int32, y: Int32) {
        pointer(x: x, y: y) { state in
            state.wheel.vertical += vertical
            state.wheel.horizontal += horizontal
            var bytes: [UInt8] = []
            func clicks(_ amount: inout Int32, positive: UInt8, negative: UInt8) {
                while abs(amount) >= 120 {
                    let bit = amount > 0 ? positive : negative
                    bytes += Self.pointerMessage(state.buttons | bit, state.pointer)
                    bytes += Self.pointerMessage(state.buttons, state.pointer)
                    amount -= amount > 0 ? 120 : -120
                }
            }
            clicks(&state.wheel.vertical, positive: 8, negative: 16)
            clicks(&state.wheel.horizontal, positive: 64, negative: 32)
            return bytes
        }
    }

    // MARK: Desktop size

    public func requestLayout(_ layout: DesktopLayout) {
        let message: [UInt8]? = shared.withLockUnchecked { state in
            let size = (Int(layout.width), Int(layout.height))
            guard state.connected, state.canResize, size.0 > 0, size.1 > 0, (state.width, state.height) != size,
                  state.requestedSize.map({ $0 != size }) ?? true else { return nil }
            state.requestedSize = size
            var message = VNCMessage(251)
            message.padding(1)
            message.u16(UInt16(clamping: size.0))
            message.u16(UInt16(clamping: size.1))
            message.u8(1)
            message.padding(1)
            message.u32(state.screen.id)
            message.u16(0); message.u16(0)
            message.u16(UInt16(clamping: size.0))
            message.u16(UInt16(clamping: size.1))
            message.u32(state.screen.flags)
            return message.bytes
        }
        if let message { stream.write(message) }
    }

    // MARK: Clipboard

    public func offerClipboard(_ content: ClipboardContent?) {
        guard parameters?.clipboard == true else { return }
        let text: String? = if case .text(let text) = content { text } else { nil }
        let message: [UInt8]? = shared.withLockUnchecked { state in
            state.localText = text
            guard state.connected else { return nil }
            if state.extendedClipboard {
                return VNCClipboard.clientMessage(VNCClipboard.flagsOnly(.notify, formats: text != nil ? VNCClipboard.textFormat : 0))
            }
            return text.map(VNCClipboard.latin1Message)
        }
        if let message { stream.write(message) }
    }

    /// VNC has no file transfer.
    public func offerFiles(_ urls: [URL]) {}

    @discardableResult
    public func fetchRemoteFiles(into directory: URL) -> Bool { false }

    public func cancelRemoteFiles() {}

    // MARK: Statistics

    public func statistics() -> RemoteStatistics? {
        var counters = AfarStatistics()
        stream.statistics(into: &counters)
        var statistics = RemoteStatistics(counters, time: ProcessInfo.processInfo.systemUptime)
        shared.withLockUnchecked { state in
            statistics.frames = state.frames
            statistics.decodeNanoseconds = state.decodeNanoseconds
            statistics.codec = state.codecUse.max { $0.value < $1.value }?.key
            state.codecUse.removeAll()
        }
        return statistics
    }
}
