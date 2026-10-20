import AfarEngine
import Foundation

/// The extended clipboard (RFB pseudo-encoding 0xC0A1E5CE): Unicode text in both directions,
/// fetched only when someone pastes. Classic VNC clipboard messages carry Latin-1 only.
///
/// Messages are ordinary cut-text messages with a negative length: 32 bits of flags (formats
/// in the low bits, one action in the high byte), then the action's data.
enum VNCClipboard {
    static let textFormat: UInt32 = 1 << 0

    enum Action: UInt32 {
        case caps = 0x0100_0000, request = 0x0200_0000, peek = 0x0400_0000
        case notify = 0x0800_0000, provide = 0x1000_0000
    }

    enum Message: Equatable {
        case caps(formats: UInt32)
        case request(formats: UInt32)
        case peek
        case notify(formats: UInt32)
        /// Text that came with a provide message, if it had any.
        case provide(text: String?)
    }

    /// The largest text this client accepts.
    static let maximumText = 32 << 20

    static func parse(_ payload: [UInt8]) throws -> Message {
        guard payload.count >= 4 else { throw VNCError.protocolError("short clipboard message") }
        let flags = payload[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let formats = flags & 0xFFFF
        // Caps lists every action the sender supports; the other messages carry one action.
        func has(_ action: Action) -> Bool { flags & action.rawValue != 0 }
        if has(.caps) { return .caps(formats: formats) }
        if has(.request) { return .request(formats: formats) }
        if has(.peek) { return .peek }
        if has(.notify) { return .notify(formats: formats) }
        if has(.provide) { return .provide(text: try providedText(Array(payload[4...]), formats: formats)) }
        throw VNCError.protocolError("clipboard action \(flags >> 24)")
    }

    /// The data of a provide message is one zlib stream: a 32-bit size and the bytes for each
    /// format in its flags, lowest first. Text is UTF-8 with CRLF line ends and a final NUL.
    private static func providedText(_ compressed: [UInt8], formats: UInt32) throws -> String? {
        guard formats & textFormat != 0 else { return nil }
        let inflater = Inflater()
        return try inflater.inflate(compressed) { data in
            var reader = MemoryReader(data)
            let size = try reader.take(4).reduce(0) { $0 << 8 | Int($1) }
            guard size <= maximumText else { throw VNCError.protocolError("clipboard text of \(size) bytes") }
            var text = String(decoding: try reader.take(size), as: UTF8.self)
            while text.hasSuffix("\0") { text.removeLast() }
            return text.replacingOccurrences(of: "\r\n", with: "\n")
        }
    }

    /// Our capabilities: text, with every action, up to `maximumText` bytes.
    static func caps() -> [UInt8] {
        var message = VNCMessage()
        message.u32(Action.caps.rawValue | Action.request.rawValue | Action.peek.rawValue
            | Action.notify.rawValue | Action.provide.rawValue | textFormat)
        message.u32(UInt32(maximumText))
        return message.bytes
    }

    static func flagsOnly(_ action: Action, formats: UInt32) -> [UInt8] {
        var message = VNCMessage()
        message.u32(action.rawValue | formats)
        return message.bytes
    }

    static func provide(_ text: String) -> [UInt8] {
        let windows = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        var body = VNCMessage()
        let bytes = Array(windows.utf8) + [0]
        body.u32(UInt32(bytes.count))
        body.append(bytes)
        var length = 0
        let compressed = body.bytes.withUnsafeBufferPointer { afar_deflate($0.baseAddress, $0.count, &length) }
        defer { free(compressed) }
        var message = VNCMessage()
        message.u32(Action.provide.rawValue | textFormat)
        if let compressed { message.append(Array(UnsafeBufferPointer(start: compressed, count: length))) }
        return message.bytes
    }

    /// Wraps an extended payload in a client cut-text message.
    static func clientMessage(_ payload: [UInt8]) -> [UInt8] {
        var message = VNCMessage(6)
        message.padding(3)
        message.s32(-Int32(payload.count))
        message.append(payload)
        return message.bytes
    }

    /// A classic cut-text message: Latin-1, other characters replaced.
    static func latin1Message(_ text: String) -> [UInt8] {
        let bytes = text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : 0x3F }
        var message = VNCMessage(6)
        message.padding(3)
        message.u32(UInt32(bytes.count))
        message.append(bytes)
        return message.bytes
    }
}
