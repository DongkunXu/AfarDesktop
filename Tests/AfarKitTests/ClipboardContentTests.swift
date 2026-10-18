@testable import AfarKit
import CoreGraphics
import Foundation
import Testing

@Test func textRoundTripUsesWindowsLineEndings() throws {
    let content = ClipboardContent.text("one\ntwo 中文")
    #expect(content.windowsText == "one\r\ntwo 中文")

    var utf16 = Data()
    for unit in "a\r\nb".utf16 + [0] { withUnsafeBytes(of: unit.littleEndian) { utf16.append(contentsOf: $0) } }
    guard case .text(let text) = ClipboardContent.fromUTF16(utf16) else { Issue.record("not text"); return }
    #expect(text == "a\nb")
}

@Test func imageSurvivesDIBAndPNG() throws {
    // A 3x2 image: red top row, blue bottom row.
    let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 3, height: 1))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 1, width: 3, height: 1))
    let content = ClipboardContent.image(context.makeImage()!)

    let dib = try #require(content.dibData)
    #expect(dib.count == 40 + 3 * 2 * 4)
    guard case .image(let fromDIB) = try #require(ClipboardContent.fromDIB(dib)) else { Issue.record("not an image"); return }
    #expect(fromDIB.width == 3 && fromDIB.height == 2)
    #expect(topLeftIsRed(fromDIB))

    let png = try #require(content.pngData)
    guard case .image(let fromPNG) = try #require(ClipboardContent.fromPNG(png)) else { Issue.record("not an image"); return }
    #expect(topLeftIsRed(fromPNG))
}

private func topLeftIsRed(_ image: CGImage) -> Bool {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw so that only the image's top-left pixel lands in the 1x1 context.
    context.draw(image, in: CGRect(x: 0, y: -CGFloat(image.height - 1), width: CGFloat(image.width), height: CGFloat(image.height)))
    return pixel[0] > 200 && pixel[2] < 50
}
