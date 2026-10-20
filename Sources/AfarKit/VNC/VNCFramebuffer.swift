import Foundation
import IOSurface

/// The remote desktop as the decoders draw it (32-bit BGRA, always opaque), and the surfaces
/// it reaches the screen through. As in the RDP engine, three surfaces take turns: the one the
/// window shows is never written, and each surface remembers the regions that changed since it
/// was last brought up to date, so presenting copies only what that surface is missing.
final class VNCFramebuffer {
    let width: Int
    let height: Int
    /// `width * height` pixels, rows top to bottom.
    let pixels: UnsafeMutablePointer<UInt32>

    private struct Surface {
        let surface: IOSurface
        var stale: [CGRect] = []
        var staleAll = true
    }

    private var surfaces: [Surface]
    private var next = 0
    private(set) var hasChanges = false
    private static let maxStale = 64

    init?(width: Int, height: Int) {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        self.width = width
        self.height = height
        pixels = .allocate(capacity: width * height)
        pixels.initialize(repeating: 0xFF00_0000, count: width * height)
        var surfaces: [Surface] = []
        for _ in 0..<3 {
            guard let surface = IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4,
                .pixelFormat: 0x4247_5241, // 'BGRA'
            ]) else { return nil }
            surfaces.append(Surface(surface: surface))
        }
        self.surfaces = surfaces
    }

    deinit {
        pixels.deallocate()
    }

    /// Clips a rectangle to the desktop; nil when nothing of it is inside.
    func clip(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        return x1 > x0 && y1 > y0 ? (x0, y0, x1 - x0, y1 - y0) : nil
    }

    func markChanged(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        guard let r = clip(x, y, w, h) else { return }
        hasChanges = true
        let rect = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
        for index in surfaces.indices where !surfaces[index].staleAll {
            if surfaces[index].stale.count == Self.maxStale {
                surfaces[index].staleAll = true
                surfaces[index].stale.removeAll()
            } else {
                surfaces[index].stale.append(rect)
            }
        }
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        guard let r = clip(x, y, w, h) else { return }
        for row in r.y..<r.y + r.h {
            (pixels + row * width + r.x).update(repeating: color, count: r.w)
        }
    }

    /// Moves a region within the desktop (CopyRect); source and destination may overlap.
    func copy(fromX: Int, fromY: Int, toX: Int, toY: Int, w: Int, h: Int) {
        guard clip(fromX, fromY, w, h) != nil, let d = clip(toX, toY, w, h),
              fromX >= 0, fromY >= 0, fromX + w <= width, fromY + h <= height else { return }
        let rows = toY > fromY ? Array((0..<d.h).reversed()) : Array(0..<d.h)
        for row in rows {
            let source = pixels + (fromY + (d.y - toY) + row) * width + fromX + (d.x - toX)
            memmove(pixels + (d.y + row) * width + d.x, source, d.w * 4)
        }
    }

    /// The next surface, brought up to date; the window should show it next.
    func present() -> IOSurface {
        var entry = surfaces[next]
        entry.surface.lock(options: [], seed: nil)
        let base = entry.surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let stride = entry.surface.bytesPerRow
        let rects = entry.staleAll ? [CGRect(x: 0, y: 0, width: width, height: height)] : entry.stale
        for rect in rects {
            let x = Int(rect.minX), w = Int(rect.width)
            for row in Int(rect.minY)..<Int(rect.maxY) {
                memcpy(base + row * stride + x * 4, pixels + row * width + x, w * 4)
            }
        }
        entry.surface.unlock(options: [], seed: nil)
        entry.stale.removeAll()
        entry.staleAll = false
        surfaces[next] = entry
        next = (next + 1) % surfaces.count
        hasChanges = false
        return entry.surface
    }
}
