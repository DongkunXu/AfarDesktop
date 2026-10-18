import AfarKit
import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// The last image of each connection's desktop, shown on its card. One small JPEG per
/// connection, overwritten on every disconnect; `ConnectionStore` deletes it with the connection.
@MainActor
@Observable
final class ThumbnailStore {
    private let paths: AppPaths
    private var cache: [UUID: NSImage] = [:]
    /// Bumped on every change so views showing a thumbnail refresh.
    private(set) var revision = 0

    init(paths: AppPaths) {
        self.paths = paths
    }

    func image(for id: UUID) -> NSImage? {
        _ = revision
        if let image = cache[id] { return image }
        guard let image = NSImage(contentsOf: paths.thumbnail(for: id)) else { return nil }
        cache[id] = image
        return image
    }

    func save(_ image: CGImage, for id: UUID) {
        let url = paths.thumbnail(for: id)
        try? FileManager.default.createDirectory(at: paths.thumbnails, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        cache[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        revision += 1
    }

    func forget(_ id: UUID) {
        cache[id] = nil
        revision += 1
    }
}
