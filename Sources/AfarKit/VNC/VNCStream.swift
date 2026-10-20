import AfarEngine
import Foundation

/// What can go wrong in a VNC session; turned into a `SessionError` when it ends.
enum VNCError: Error {
    case stream(AfarStreamStatus)
    /// The server sent something this client does not understand.
    case protocolError(String)
    /// The server wants something this client cannot do (a security type, for example).
    case unsupported(String)
    /// The server refused the credentials.
    case authentication(String?)
    /// The server refused the connection before authentication.
    case refused(String?)
    case certificateRejected
    /// The user cancelled a question (credentials).
    case cancelled
}

/// Reads RFB values (big-endian) from bytes that arrive over the network.
protocol ByteSource: AnyObject {
    func read(into buffer: UnsafeMutableRawBufferPointer) throws
}

extension ByteSource {
    func u8() throws -> UInt8 {
        var value: UInt8 = 0
        try withUnsafeMutableBytes(of: &value) { try read(into: $0) }
        return value
    }

    func u16() throws -> UInt16 {
        var value: UInt16 = 0
        try withUnsafeMutableBytes(of: &value) { try read(into: $0) }
        return UInt16(bigEndian: value)
    }

    func u32() throws -> UInt32 {
        var value: UInt32 = 0
        try withUnsafeMutableBytes(of: &value) { try read(into: $0) }
        return UInt32(bigEndian: value)
    }

    func s32() throws -> Int32 { Int32(bitPattern: try u32()) }

    func bytes(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { try read(into: $0) }
        return bytes
    }

    func skip(_ count: Int) throws {
        var remaining = count
        var scratch = [UInt8](repeating: 0, count: min(max(count, 1), 65536))
        while remaining > 0 {
            let chunk = min(remaining, scratch.count)
            try scratch.withUnsafeMutableBytes { try read(into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<chunk])) }
            remaining -= chunk
        }
    }

    /// A string with a 32-bit length in front, as RFB sends reasons and names.
    func string(maximum: Int = 1 << 20) throws -> String {
        let length = Int(try u32())
        guard length <= maximum else { throw VNCError.protocolError("string of \(length) bytes") }
        return String(decoding: try bytes(length), as: UTF8.self)
    }
}

/// The connection to the server: an `AfarStream` read on the session thread, written from any.
final class VNCStream: ByteSource, @unchecked Sendable {
    private let stream: OpaquePointer

    init() {
        guard let stream = afar_stream_new() else { fatalError("could not create a VNC stream (out of file descriptors)") }
        self.stream = stream
    }

    deinit {
        afar_stream_free(stream)
    }

    func connect(host: String, port: UInt16, timeout: Duration) throws {
        let milliseconds = Int32(timeout.components.seconds * 1000)
        try check(afar_stream_connect(stream, host, port, milliseconds))
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        try check(afar_stream_read(stream, base, buffer.count))
    }

    func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { afar_stream_write(stream, $0.baseAddress, $0.count) }
    }

    /// Sends what is queued and switches to TLS; returns the server's certificate, if any.
    func startTLS(serverName: String, anonymous: Bool) throws -> AfarPeerCertificate {
        var peer = AfarPeerCertificate()
        try check(afar_stream_start_tls(stream, serverName, anonymous, &peer))
        return peer
    }

    func cancel() {
        afar_stream_cancel(stream)
    }

    func statistics(into statistics: inout AfarStatistics) {
        afar_stream_statistics(stream, &statistics)
    }

    /// Nanoseconds spent waiting for data, to tell decoding time from transfer time.
    var waitNanoseconds: UInt64 { afar_stream_wait_nanoseconds(stream) }

    private func check(_ status: AfarStreamStatus) throws {
        guard status == AfarStreamOK else { throw VNCError.stream(status) }
    }
}

/// Bytes already in memory, such as an inflated zlib chunk, read with bounds checks.
struct MemoryReader {
    let bytes: UnsafeRawBufferPointer
    private(set) var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw VNCError.protocolError("compressed data ended early") }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// The next `count` bytes, without copying.
    mutating func take(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard count >= 0, count <= remaining else { throw VNCError.protocolError("compressed data ended early") }
        defer { offset += count }
        return UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + count])
    }
}

/// An outgoing RFB message, built field by field.
struct VNCMessage {
    private(set) var bytes: [UInt8] = []

    init(_ type: UInt8) {
        bytes.append(type)
    }

    init() {}

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes += [UInt8(value >> 8), UInt8(value & 0xFF)] }
    mutating func u32(_ value: UInt32) {
        bytes += [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    mutating func s32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func padding(_ count: Int) { bytes += [UInt8](repeating: 0, count: count) }
    mutating func append(_ data: [UInt8]) { bytes += data }
}

/// One zlib stream that keeps its dictionary from rectangle to rectangle.
final class Inflater {
    private let inflater: OpaquePointer

    init() {
        guard let inflater = afar_inflater_new() else { fatalError("zlib could not start") }
        self.inflater = inflater
    }

    deinit {
        afar_inflater_free(inflater)
    }

    func reset() {
        afar_inflater_reset(inflater)
    }

    /// Inflates `input` and lets `body` read the result, which is only valid during the call.
    func inflate<T>(_ input: [UInt8], _ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        var length = 0
        let output = input.withUnsafeBufferPointer { afar_inflate(inflater, $0.baseAddress, $0.count, &length) }
        guard let output else { throw VNCError.protocolError("corrupt zlib data") }
        return try body(UnsafeRawBufferPointer(start: output, count: length))
    }
}
