import CoreGraphics
import Foundation
import ImageIO

/// RFB encodings this client understands, in the numbering of the protocol.
enum VNCEncoding: Int32 {
    case raw = 0
    case copyRect = 1
    case hextile = 5
    case tight = 7
    case zrle = 16

    // Pseudo-encodings: announcements and settings, not pixels.
    case cursor = -239
    case desktopSize = -223
    case lastRect = -224
    case extendedDesktopSize = -308
    case desktopName = -307
    case qemuExtendedKeyEvent = -258
    case extendedClipboard = -1_063_131_698 // 0xC0A1E5CE
    /// Tight JPEG quality 0...9 is sent as -32...-23, compression level 0...9 as -256...-247.
    static func jpegQuality(_ level: Int32) -> Int32 { -32 + level }
    static func compressLevel(_ level: Int32) -> Int32 { -256 + level }
}

/// Draws rectangles of the encodings above into a framebuffer. Keeps the zlib streams, which
/// carry their state from one rectangle to the next for the whole connection.
///
/// The client asks for 32-bit little-endian pixels with red, green and blue in bits 16, 8 and
/// 0, which is BGRA in memory: raw pixels go straight in, with the unused byte set to opaque.
final class VNCDecoder {
    private let zrle = Inflater()
    private let tight = (0..<4).map { _ in Inflater() }
    /// The codec of the last pixel rectangle, for statistics.
    private(set) var lastCodec: VideoCodec?

    private static let opaque: UInt32 = 0xFF00_0000

    /// Draws one rectangle; the caller has read its header.
    func decode(_ encoding: VNCEncoding, x: Int, y: Int, w: Int, h: Int, from source: ByteSource,
                into framebuffer: VNCFramebuffer) throws {
        switch encoding {
        case .raw:
            try raw(x, y, w, h, source, framebuffer)
            lastCodec = .uncompressed
        case .copyRect:
            let fromX = Int(try source.u16()), fromY = Int(try source.u16())
            framebuffer.copy(fromX: fromX, fromY: fromY, toX: x, toY: y, w: w, h: h)
        case .hextile:
            try hextile(x, y, w, h, source, framebuffer)
            lastCodec = .hextile
        case .zrle:
            try zrle(x, y, w, h, source, framebuffer)
            lastCodec = .zrle
        case .tight:
            try tight(x, y, w, h, source, framebuffer)
        default:
            throw VNCError.protocolError("encoding \(encoding.rawValue) has no pixels")
        }
        framebuffer.markChanged(x, y, w, h)
    }

    // MARK: Raw

    private func raw(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ source: ByteSource, _ fb: VNCFramebuffer) throws {
        guard w > 0, h > 0 else { return }
        var row = [UInt32](repeating: 0, count: w)
        for line in 0..<h {
            try row.withUnsafeMutableBytes { try source.read(into: $0) }
            for i in row.indices { row[i] = UInt32(littleEndian: row[i]) } // as sent
            store(row, at: x, y + line, in: fb)
        }
    }

    /// Copies a row of pixels, clipped to the desktop and made opaque.
    private func store(_ row: [UInt32], at x: Int, _ y: Int, in fb: VNCFramebuffer) {
        guard y >= 0, y < fb.height else { return }
        let start = max(0, -x), end = min(row.count, fb.width - x)
        guard start < end else { return }
        let target = fb.pixels + y * fb.width + x
        for i in start..<end { target[i] = row[i] | Self.opaque }
    }

    // MARK: Hextile

    private func hextile(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ source: ByteSource, _ fb: VNCFramebuffer) throws {
        var background: UInt32 = Self.opaque, foreground: UInt32 = Self.opaque
        // Pixels are little-endian on the wire; u32() reads big-endian.
        func pixel() throws -> UInt32 { try source.u32().byteSwapped | Self.opaque }
        for ty in stride(from: y, to: y + h, by: 16) {
            for tx in stride(from: x, to: x + w, by: 16) {
                let tw = min(16, x + w - tx), th = min(16, y + h - ty)
                let flags = try source.u8()
                if flags & 1 != 0 { // raw tile
                    try raw(tx, ty, tw, th, source, fb)
                    continue
                }
                if flags & 2 != 0 { background = try pixel() }
                fb.fill(tx, ty, tw, th, background)
                if flags & 4 != 0 { foreground = try pixel() }
                guard flags & 8 != 0 else { continue }
                let count = Int(try source.u8())
                for _ in 0..<count {
                    let color = flags & 16 != 0 ? try pixel() : foreground
                    let position = try source.u8(), size = try source.u8()
                    fb.fill(tx + Int(position >> 4), ty + Int(position & 15), Int(size >> 4) + 1, Int(size & 15) + 1, color)
                }
            }
        }
    }

    // MARK: ZRLE

    private func zrle(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ source: ByteSource, _ fb: VNCFramebuffer) throws {
        let length = Int(try source.u32())
        guard length <= 64 << 20 else { throw VNCError.protocolError("ZRLE rectangle of \(length) bytes") }
        let compressed = try source.bytes(length)
        try zrle.inflate(compressed) { data in
            var reader = MemoryReader(data)
            for ty in stride(from: y, to: y + h, by: 64) {
                for tx in stride(from: x, to: x + w, by: 64) {
                    try zrleTile(tx, ty, min(64, x + w - tx), min(64, y + h - ty), &reader, fb)
                }
            }
        }
    }

    /// ZRLE pixels are the three low bytes of a pixel, in its byte order: blue, green, red.
    private static func cpixel(_ reader: inout MemoryReader) throws -> UInt32 {
        let p = try reader.take(3)
        return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | opaque
    }

    private func zrleTile(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ reader: inout MemoryReader, _ fb: VNCFramebuffer) throws {
        let kind = Int(try reader.u8())
        var tile = [UInt32](repeating: 0, count: w * h)
        switch kind {
        case 0: // raw
            for i in 0..<tile.count { tile[i] = try Self.cpixel(&reader) }
        case 1: // solid
            fb.fill(x, y, w, h, try Self.cpixel(&reader))
            return
        case 2...16: // packed palette
            let palette = try (0..<kind).map { _ in try Self.cpixel(&reader) }
            let bits = kind == 2 ? 1 : (kind <= 4 ? 2 : 4)
            let mask = (1 << bits) - 1
            for row in 0..<h {
                let packed = try reader.take((w * bits + 7) / 8)
                for column in 0..<w {
                    let bit = column * bits
                    let index = (Int(packed[bit / 8]) >> (8 - bits - bit % 8)) & mask
                    guard index < palette.count else { throw VNCError.protocolError("ZRLE palette index") }
                    tile[row * w + column] = palette[index]
                }
            }
        case 128: // plain run-length
            var i = 0
            while i < tile.count {
                let color = try Self.cpixel(&reader)
                let run = try Self.runLength(&reader)
                guard i + run <= tile.count else { throw VNCError.protocolError("ZRLE run too long") }
                for j in i..<i + run { tile[j] = color }
                i += run
            }
        case 130...255: // palette run-length
            let palette = try (0..<kind - 128).map { _ in try Self.cpixel(&reader) }
            var i = 0
            while i < tile.count {
                let index = Int(try reader.u8())
                guard index & 0x7F < palette.count else { throw VNCError.protocolError("ZRLE palette index") }
                let run = index & 0x80 != 0 ? try Self.runLength(&reader) : 1
                guard i + run <= tile.count else { throw VNCError.protocolError("ZRLE run too long") }
                for j in i..<i + run { tile[j] = palette[index & 0x7F] }
                i += run
            }
        default:
            throw VNCError.protocolError("ZRLE tile kind \(kind)")
        }
        for row in 0..<h {
            store(Array(tile[row * w..<(row + 1) * w]), at: x, y + row, in: fb)
        }
    }

    private static func runLength(_ reader: inout MemoryReader) throws -> Int {
        var length = 1
        var byte: UInt8
        repeat {
            byte = try reader.u8()
            length += Int(byte)
        } while byte == 255
        return length
    }

    // MARK: Tight

    /// Tight pixels are red, green and blue, one byte each.
    private static func tpixel(_ p: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(p[offset]) << 16 | UInt32(p[offset + 1]) << 8 | UInt32(p[offset + 2]) | opaque
    }

    /// Tight's lengths take one to three bytes, seven bits each.
    static func compactLength(_ source: ByteSource) throws -> Int {
        var length = 0
        for shift in [0, 7, 14] {
            let byte = Int(try source.u8())
            length |= (shift == 14 ? byte : byte & 0x7F) << shift
            if shift == 14 || byte & 0x80 == 0 { break }
        }
        return length
    }

    private func tight(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ source: ByteSource, _ fb: VNCFramebuffer) throws {
        let control = try source.u8()
        for stream in 0..<4 where control & (1 << stream) != 0 { tight[stream].reset() }
        let method = control >> 4

        if method == 8 { // fill
            let p = try source.bytes(3)
            fb.fill(x, y, w, h, UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]) | Self.opaque)
            lastCodec = .tight
            return
        }
        if method == 9 { // JPEG
            let data = try source.bytes(try Self.compactLength(source))
            try jpeg(Data(data), x, y, w, h, fb)
            lastCodec = .tightJPEG
            return
        }
        guard method < 8 else { throw VNCError.protocolError("Tight method \(method)") }
        lastCodec = .tight

        let stream = Int(method & 3)
        let filter = method & 4 != 0 ? try source.u8() : 0
        var palette: [UInt32] = []
        let rowBytes: Int
        switch filter {
        case 0, 2: // copy, gradient
            rowBytes = w * 3
        case 1: // palette
            let count = Int(try source.u8()) + 1
            let colors = try source.bytes(count * 3)
            palette = colors.withUnsafeBytes { p in (0..<count).map { Self.tpixel(p, $0 * 3) } }
            rowBytes = count == 2 ? (w + 7) / 8 : w
        default:
            throw VNCError.protocolError("Tight filter \(filter)")
        }

        let size = rowBytes * h
        let render: (UnsafeRawBufferPointer) throws -> Void = { data in
            guard data.count >= size else { throw VNCError.protocolError("Tight data too short") }
            switch filter {
            case 1: self.tightPalette(data, palette, rowBytes, x, y, w, h, fb)
            case 2: self.tightGradient(data, x, y, w, h, fb)
            default: self.tightCopy(data, x, y, w, h, fb)
            }
        }
        if size < 12 { // too small to be worth compressing: sent as is
            let data = try source.bytes(size)
            try data.withUnsafeBytes(render)
        } else {
            let compressed = try source.bytes(try Self.compactLength(source))
            try tight[stream].inflate(compressed, render)
        }
    }

    private func tightCopy(_ data: UnsafeRawBufferPointer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fb: VNCFramebuffer) {
        var row = [UInt32](repeating: 0, count: w)
        for line in 0..<h {
            for column in 0..<w { row[column] = Self.tpixel(data, (line * w + column) * 3) }
            store(row, at: x, y + line, in: fb)
        }
    }

    private func tightPalette(_ data: UnsafeRawBufferPointer, _ palette: [UInt32], _ rowBytes: Int,
                              _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fb: VNCFramebuffer) {
        var row = [UInt32](repeating: 0, count: w)
        for line in 0..<h {
            for column in 0..<w {
                let index = palette.count == 2
                    ? Int(data[line * rowBytes + column / 8] >> (7 - column % 8)) & 1
                    : Int(data[line * rowBytes + column])
                row[column] = index < palette.count ? palette[index] : Self.opaque
            }
            store(row, at: x, y + line, in: fb)
        }
    }

    /// Each component was sent as the difference from a prediction made from the pixels to the
    /// left, above and above-left (libvncclient's FilterGradient24).
    private func tightGradient(_ data: UnsafeRawBufferPointer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fb: VNCFramebuffer) {
        var previous = [UInt8](repeating: 0, count: w * 3)
        var current = [UInt8](repeating: 0, count: w * 3)
        var row = [UInt32](repeating: 0, count: w)
        for line in 0..<h {
            for column in 0..<w {
                for c in 0..<3 {
                    let index = column * 3 + c
                    let estimate: Int
                    if column == 0 {
                        estimate = Int(previous[index])
                    } else {
                        estimate = min(255, max(0, Int(previous[index]) + Int(current[index - 3]) - Int(previous[index - 3])))
                    }
                    current[index] = UInt8(truncatingIfNeeded: estimate &+ Int(data[(line * w + column) * 3 + c]))
                }
                row[column] = UInt32(current[column * 3]) << 16 | UInt32(current[column * 3 + 1]) << 8
                    | UInt32(current[column * 3 + 2]) | Self.opaque
            }
            store(row, at: x, y + line, in: fb)
            swap(&previous, &current)
        }
    }

    private func jpeg(_ data: Data, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fb: VNCFramebuffer) throws {
        guard let r = fb.clip(x, y, w, h) else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VNCError.protocolError("unreadable JPEG rectangle")
        }
        // Draw straight into the framebuffer: the context's first row is the rectangle's top.
        guard let context = CGContext(
            data: fb.pixels + y * fb.width + x, width: w, height: h, bitsPerComponent: 8, bytesPerRow: fb.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            r.x == x, r.y == y, r.w == w, r.h == h
        else { return }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for line in 0..<h {
            let target = fb.pixels + (y + line) * fb.width + x
            for i in 0..<w { target[i] |= Self.opaque }
        }
    }
}
