import AfarKit
import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What shows behind the main window, and the accent colour taken from it: one of the pictures
/// that come with the app, a picture of the user's own or a solid colour.
///
/// A picture of the user's own is copied (scaled down, one JPEG) into Application Support, so the
/// original can move or disappear; it stays there to switch back to until it is removed.
@MainActor
@Observable
final class Backdrop {
    enum Choice: Hashable {
        /// A picture from the app bundle, numbered from 1.
        case builtIn(Int)
        case ownPicture
        case color(RGB)
    }

    struct RGB: Hashable {
        var red, green, blue: Double

        var color: Color { Color(nsColor: nsColor) }
        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init?(_ color: NSColor) {
            guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
            self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        }
    }

    private(set) var choice: Choice
    /// The picture shown, for the built-in and own-picture choices.
    private(set) var image: NSImage?
    /// A colour from the picture (or the solid colour) for highlights; nil when it has none.
    private(set) var accent: Color?
    /// The user's own picture is on disk.
    private(set) var hasOwnPicture: Bool

    /// How strongly the background shows through, 0...1.
    var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: Keys.opacity) }
    }

    /// The pictures that come with the app, in order.
    let builtIns: [URL]

    @ObservationIgnored private let ownPicture: URL
    @ObservationIgnored private var thumbnails: [URL: NSImage] = [:]
    private static let maxPixels: CGFloat = 3200
    static let defaultColor = RGB(red: 0.16, green: 0.17, blue: 0.20)

    init(paths: AppPaths, bundle: Bundle = .main) {
        ownPicture = paths.backdrop
        builtIns = (bundle.urls(forResourcesWithExtension: "jpg", subdirectory: "Backgrounds") ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        hasOwnPicture = FileManager.default.fileExists(atPath: paths.backdrop.path)
        opacity = UserDefaults.standard.object(forKey: Keys.opacity) as? Double ?? 0.35
        choice = .builtIn(1)
        choice = Self.choice(from: UserDefaults.standard.string(forKey: Keys.choice)) ?? defaultChoice
        load()
    }

    /// The first built-in picture; the user's own picture when one was set before choices existed.
    private var defaultChoice: Choice {
        hasOwnPicture ? .ownPicture : (builtIns.isEmpty ? .color(Self.defaultColor) : .builtIn(1))
    }

    func select(_ choice: Choice) {
        guard choice != self.choice else { return }
        apply(choice)
    }

    private func apply(_ choice: Choice) {
        self.choice = choice
        UserDefaults.standard.set(Self.string(for: choice), forKey: Keys.choice)
        load()
    }

    /// Copies a picture of the user's own and shows it.
    func importPicture(from url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Self.maxPixels,
              ] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: ownPicture.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(ownPicture as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        hasOwnPicture = true
        thumbnails[ownPicture] = nil
        apply(.ownPicture)
    }

    func removeOwnPicture() {
        try? FileManager.default.removeItem(at: ownPicture)
        hasOwnPicture = false
        thumbnails[ownPicture] = nil
        if choice == .ownPicture { apply(defaultChoice) }
    }

    /// A small version of a built-in picture (1-based) or the own picture (nil), for pickers.
    func thumbnail(builtIn number: Int?) -> NSImage? {
        guard let url = number.map({ builtIns.indices.contains($0 - 1) ? builtIns[$0 - 1] : nil }) ?? ownPicture
        else { return nil }
        if let cached = thumbnails[url] { return cached }
        guard let image = Self.loadImage(url, maxPixels: 200) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails[url] = thumbnail
        return thumbnail
    }

    private func load() {
        let url: URL?
        switch choice {
        case .builtIn(let number): url = builtIns.indices.contains(number - 1) ? builtIns[number - 1] : nil
        case .ownPicture: url = hasOwnPicture ? ownPicture : nil
        case .color(let rgb):
            image = nil
            accent = Self.accent(of: rgb.nsColor).map(Color.init(nsColor:))
            return
        }
        guard let url, let cgImage = Self.loadImage(url, maxPixels: nil) else {
            image = nil
            accent = nil
            return
        }
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        accent = Self.accent(of: cgImage).map(Color.init(nsColor:))
    }

    private static func loadImage(_ url: URL, maxPixels: CGFloat?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let maxPixels else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    // MARK: Accent

    /// A solid colour is its own accent when it is colourful enough.
    static func accent(of color: NSColor) -> NSColor? {
        guard let srgb = color.usingColorSpace(.sRGB), srgb.saturationComponent > 0.25 else { return nil }
        return NSColor(hue: srgb.hueComponent,
                       saturation: min(0.85, max(0.45, srgb.saturationComponent)),
                       brightness: min(0.95, max(0.6, srgb.brightnessComponent)),
                       alpha: 1)
    }

    /// The most prominent vivid hue in the picture, adjusted to work as an accent colour.
    static func accent(of image: CGImage) -> NSColor? {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Twelve hue bins, each weighted by how vivid its pixels are.
        var weight = [CGFloat](repeating: 0, count: 12)
        var sum = [(CGFloat, CGFloat, CGFloat)](repeating: (0, 0, 0), count: 12)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.25, brightness > 0.25 else { continue }
            let bin = min(11, Int(hue * 12))
            let w = saturation * brightness
            weight[bin] += w
            sum[bin].0 += hue * w
            sum[bin].1 += saturation * w
            sum[bin].2 += brightness * w
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 1 else { return nil }
        let w = weight[best]
        return NSColor(hue: sum[best].0 / w,
                       saturation: min(0.85, max(0.45, sum[best].1 / w)),
                       brightness: min(0.95, max(0.6, sum[best].2 / w)),
                       alpha: 1)
    }

    // MARK: Storage

    private enum Keys {
        static let choice = "Backdrop"
        static let opacity = "BackdropOpacity"
    }

    /// "builtin:3", "own", "color:0.1,0.2,0.3"
    private static func string(for choice: Choice) -> String {
        switch choice {
        case .builtIn(let number): "builtin:\(number)"
        case .ownPicture: "own"
        case .color(let rgb): "color:\(rgb.red),\(rgb.green),\(rgb.blue)"
        }
    }

    private static func choice(from string: String?) -> Choice? {
        guard let string else { return nil }
        if string == "own" { return .ownPicture }
        if string.hasPrefix("builtin:"), let number = Int(string.dropFirst(8)) { return .builtIn(number) }
        if string.hasPrefix("color:") {
            let parts = string.dropFirst(6).split(separator: ",").compactMap { Double($0) }
            if parts.count == 3 { return .color(RGB(red: parts[0], green: parts[1], blue: parts[2])) }
        }
        return nil
    }
}

extension EnvironmentValues {
    /// The app's highlight colour: from the background, or the system accent.
    @Entry var appAccent: Color = .accentColor
}
