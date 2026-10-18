import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What can travel over the shared clipboard, and its conversion to and from the RDP formats:
/// UTF-16 text with CRLF line endings, PNG files and Windows DIBs.
public enum ClipboardContent: @unchecked Sendable {
    case text(String)
    case image(CGImage)

    // MARK: Remote formats → content

    /// Text as Windows sends it: UTF-16LE, CRLF, usually NUL-terminated.
    static func fromUTF16(_ data: Data) -> ClipboardContent? {
        var units = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: UInt16.self)).map { UInt16(littleEndian: $0) }
        }
        if let end = units.firstIndex(of: 0) { units.removeSubrange(end...) }
        let text = String(decoding: units, as: UTF16.self).replacingOccurrences(of: "\r\n", with: "\n")
        return .text(text)
    }

    static func fromPNG(_ data: Data) -> ClipboardContent? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return .image(image)
    }

    /// A DIB is a BMP file without its 14-byte file header; adding the header lets ImageIO read it.
    static func fromDIB(_ dib: Data) -> ClipboardContent? {
        guard dib.count >= 40 else { return nil }
        func u32(_ offset: Int) -> UInt32 { dib.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } }
        func u16(_ offset: Int) -> UInt16 { dib.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian } }
        let headerSize = u32(0)
        let bitCount = u16(14)
        let compression = u32(16)
        let colorsUsed = u32(32)
        let colors = colorsUsed != 0 ? colorsUsed : (bitCount <= 8 ? UInt32(1) << bitCount : 0)
        let masks: UInt32 = headerSize == 40 && compression == 3 ? 12 : 0 // BI_BITFIELDS
        let pixelOffset = 14 + headerSize + masks + colors * 4

        var file = Data()
        file.append(contentsOf: [0x42, 0x4D]) // "BM"
        file.appendLittleEndian(UInt32(14 + dib.count))
        file.appendLittleEndian(UInt32(0))
        file.appendLittleEndian(pixelOffset)
        file.append(dib)
        guard let source = CGImageSourceCreateWithData(file as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return .image(image)
    }

    // MARK: Content → remote formats

    /// The text for the remote side, with Windows line endings.
    var windowsText: String? {
        guard case .text(let text) = self else { return nil }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    var pngData: Data? {
        guard case .image(let image) = self else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A 32-bit bottom-up DIB with a BITMAPINFOHEADER, the form every Windows app reads.
    var dibData: Data? {
        guard case .image(let image) = self else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let stride = width * 4
        var pixels = Data(count: stride * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            // BGRA in memory, premultiplied alpha, drawn flipped so the first row is the bottom one.
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var dib = Data()
        dib.appendLittleEndian(UInt32(40))     // biSize
        dib.appendLittleEndian(Int32(width))   // biWidth
        dib.appendLittleEndian(Int32(height))  // biHeight (positive: bottom-up)
        dib.appendLittleEndian(UInt16(1))      // biPlanes
        dib.appendLittleEndian(UInt16(32))     // biBitCount
        dib.appendLittleEndian(UInt32(0))      // biCompression = BI_RGB
        dib.appendLittleEndian(UInt32(pixels.count))
        dib.appendLittleEndian(Int32(2835))    // 72 dpi
        dib.appendLittleEndian(Int32(2835))
        dib.appendLittleEndian(UInt32(0))      // biClrUsed
        dib.appendLittleEndian(UInt32(0))      // biClrImportant
        dib.append(pixels)
        return dib
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
