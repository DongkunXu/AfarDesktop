import AfarEngine
@testable import AfarKit
import Foundation
import Testing

/// Bytes handed to a decoder as if they came from the server.
private final class DataSource: ByteSource {
    private var bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isConsumed: Bool { offset == bytes.count }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws {
        guard offset + buffer.count <= bytes.count else { throw VNCError.protocolError("test data ended") }
        buffer.copyBytes(from: bytes[offset..<offset + buffer.count])
        offset += buffer.count
    }
}

private func deflate(_ bytes: [UInt8]) -> [UInt8] {
    var length = 0
    let output = bytes.withUnsafeBufferPointer { afar_deflate($0.baseAddress, $0.count, &length) }!
    defer { free(output) }
    return Array(UnsafeBufferPointer(start: output, count: length))
}

private func be32(_ value: Int) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// The framebuffer's pixels as 0xRRGGBB, row by row.
private func colors(_ fb: VNCFramebuffer) -> [UInt32] {
    (0..<fb.width * fb.height).map { fb.pixels[$0] & 0xFF_FFFF }
}

@Test func zrlePaletteRunLength() throws {
    let fb = try #require(VNCFramebuffer(width: 4, height: 2))
    // Tile kind 130: two palette colours (CPIXELs are blue, green, red), then runs.
    let tile: [UInt8] = [130, 0x03, 0x02, 0x01, 0xFF, 0x00, 0x00,
                         0x80 | 0, 4,   // colour 0, run of 1 + 4 = 5
                         1, 1, 1]       // three single pixels of colour 1
    let compressed = deflate(tile)
    let source = DataSource(be32(compressed.count) + compressed)
    try VNCDecoder().decode(.zrle, x: 0, y: 0, w: 4, h: 2, from: source, into: fb)
    #expect(colors(fb) == [0x010203, 0x010203, 0x010203, 0x010203, 0x010203, 0x0000FF, 0x0000FF, 0x0000FF])
    #expect(source.isConsumed)
    #expect(fb.pixels[0] >> 24 == 0xFF) // opaque
}

@Test func zrlePackedPalette() throws {
    let fb = try #require(VNCFramebuffer(width: 3, height: 2))
    // Kind 2: two colours, one bit per pixel, rows padded to whole bytes.
    let tile: [UInt8] = [2, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0b1010_0000, 0b0100_0000]
    let compressed = deflate(tile)
    try VNCDecoder().decode(.zrle, x: 0, y: 0, w: 3, h: 2, from: DataSource(be32(compressed.count) + compressed), into: fb)
    #expect(colors(fb) == [0xFFFFFF, 0, 0xFFFFFF, 0, 0xFFFFFF, 0])
}

@Test func tightFillAndTwoColourPalette() throws {
    let fb = try #require(VNCFramebuffer(width: 8, height: 2))
    let decoder = VNCDecoder()
    // Fill (method 8): one pixel in red, green, blue order.
    try decoder.decode(.tight, x: 0, y: 0, w: 8, h: 2, from: DataSource([0x80, 0x10, 0x20, 0x30]), into: fb)
    #expect(colors(fb).allSatisfy { $0 == 0x102030 })
    // Basic compression with the palette filter (0x40), two colours: 1 bit per pixel; under 12
    // bytes, so sent uncompressed.
    let source = DataSource([0x40, 1, 1, 0xFF, 0, 0, 0, 0, 0xFF, 0b1000_0001, 0b0111_1110])
    try decoder.decode(.tight, x: 0, y: 0, w: 8, h: 2, from: source, into: fb)
    #expect(colors(fb) == [0x0000FF, 0xFF0000, 0xFF0000, 0xFF0000, 0xFF0000, 0xFF0000, 0xFF0000, 0x0000FF,
                           0xFF0000, 0x0000FF, 0x0000FF, 0x0000FF, 0x0000FF, 0x0000FF, 0x0000FF, 0xFF0000])
    #expect(decoder.lastCodec == .tight)
}

@Test func tightGradient() throws {
    let fb = try #require(VNCFramebuffer(width: 3, height: 1))
    // One row: the prediction is the pixel to the left, so the data holds differences.
    let source = DataSource([0x40, 2, 10, 20, 30, 1, 1, 1, 2, 2, 2])
    try VNCDecoder().decode(.tight, x: 0, y: 0, w: 3, h: 1, from: source, into: fb)
    #expect(colors(fb) == [0x0A141E, 0x0B151F, 0x0D1721])
}

@Test func tightCompressedCopy() throws {
    let fb = try #require(VNCFramebuffer(width: 4, height: 1))
    let pixels: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] // 12 bytes: compressed
    let compressed = deflate(pixels)
    try VNCDecoder().decode(.tight, x: 0, y: 0, w: 4, h: 1, from: DataSource([0x00, UInt8(compressed.count)] + compressed), into: fb)
    #expect(colors(fb) == [0x010203, 0x040506, 0x070809, 0x0A0B0C])
}

@Test func hextileBackgroundAndSubrect() throws {
    let fb = try #require(VNCFramebuffer(width: 4, height: 4))
    // Background (2) + foreground (4) + subrects (8): one 2x2 subrect at (1,1).
    let pixel: (UInt8, UInt8, UInt8) -> [UInt8] = { r, g, b in [b, g, r, 0] }
    let source = DataSource([2 | 4 | 8] + pixel(0, 0, 0x40) + pixel(0xFF, 0, 0) + [1, 0x11, 0x11])
    try VNCDecoder().decode(.hextile, x: 0, y: 0, w: 4, h: 4, from: source, into: fb)
    let red: UInt32 = 0xFF0000, blue: UInt32 = 0x40
    #expect(colors(fb) == [blue, blue, blue, blue, blue, red, red, blue, blue, red, red, blue, blue, blue, blue, blue])
}

@Test func copyRectOverlapping() throws {
    let fb = try #require(VNCFramebuffer(width: 3, height: 3))
    for i in 0..<9 { fb.pixels[i] = UInt32(i) | 0xFF00_0000 }
    // Move the top-left 2x2 one pixel down and right.
    try VNCDecoder().decode(.copyRect, x: 1, y: 1, w: 2, h: 2, from: DataSource([0, 0, 0, 0]), into: fb)
    #expect(colors(fb) == [0, 1, 2, 3, 0, 1, 6, 3, 4])
}

@Test func compactLengths() throws {
    #expect(try VNCDecoder.compactLength(DataSource([0x05])) == 5)
    #expect(try VNCDecoder.compactLength(DataSource([0x81, 0x01])) == 129)
    #expect(try VNCDecoder.compactLength(DataSource([0xFF, 0xFF, 0xFF])) == 0x3F_FFFF)
}

@Test func extendedClipboardRoundTrip() throws {
    let message = VNCClipboard.provide("one\ntwo 中文")
    #expect(try VNCClipboard.parse(message) == .provide(text: "one\ntwo 中文"))
    // A caps message lists several actions at once.
    #expect(try VNCClipboard.parse(VNCClipboard.caps()) == .caps(formats: VNCClipboard.textFormat))
    #expect(try VNCClipboard.parse(VNCClipboard.flagsOnly(.notify, formats: 1)) == .notify(formats: 1))
}

@Test func vncPasswordKeyBits() {
    #expect(VNCSecurity.reversedBits(0b0000_0001) == 0b1000_0000)
    #expect(VNCSecurity.reversedBits(0b1100_1010) == 0b0101_0011)
}

@Test func encodingPreferenceFollowsColour() {
    let lossless = VNCSession.encodings(fullColor: true, clipboard: true)
    #expect(lossless.first == VNCEncoding.zrle.rawValue)
    #expect(!lossless.contains(VNCEncoding.jpegQuality(8)))
    #expect(lossless.contains(VNCEncoding.extendedClipboard.rawValue))
    let compressed = VNCSession.encodings(fullColor: false, clipboard: false)
    #expect(compressed.first == VNCEncoding.tight.rawValue)
    #expect(compressed.contains(VNCEncoding.jpegQuality(8)))
    #expect(!compressed.contains(VNCEncoding.extendedClipboard.rawValue))
}

@Test func keysymsFollowShift() {
    #expect(VNCKeymap.key(for: 0x00)?.keysym == 0x61)  // a
    #expect(VNCKeymap.key(for: 0x00)?.shifted == 0x41) // A
    #expect(VNCKeymap.key(for: 0x12)?.shifted == 0x21) // 1 → !
    #expect(VNCKeymap.key(for: 0x7A)?.keysym == 0xFFBE) // F1
    #expect(VNCKeymap.scancode(for: 0x7E) == 0xC8) // up arrow: extended 0x48
}

@Test func vncAddressesAndPasswords() {
    #expect(RemoteProtocol.vnc.port(fromAddress: 1) == 5901) // display number
    #expect(RemoteProtocol.vnc.port(fromAddress: 5905) == 5905)
    #expect(RemoteProtocol.rdp.port(fromAddress: 1) == 1)
    let pi = Connection(remoteProtocol: .vnc, host: "pi.local")
    #expect(pi.port == 5900 && pi.address == "pi.local")
    #expect(CredentialStore.Key(pi).isUsable) // a password without a user name
    #expect(!CredentialStore.Key(Connection(host: "pc.local")).isUsable)
}

@Test func detectorReadsGreetings() {
    #expect(ProtocolDetector.classify(Array("RFB 003.008\n".utf8)) == .vnc)
    #expect(ProtocolDetector.classify([0x03, 0x00, 0x00, 0x13, 0x0E, 0xD0]) == .rdp)
    #expect(ProtocolDetector.classify(Array("HTTP/1.1".utf8)) == nil)
    #expect(ProtocolDetector.rdpConnectionRequest.count == 0x13)
}
