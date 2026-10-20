import CoreGraphics

/// The remote desktop size and scale for a window, following a connection's display options.
public struct DesktopLayout: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    /// Percent; how large the remote desktop draws its interface.
    public var desktopScale: UInt32
    /// Percent; 100, 140 or 180, derived from the desktop scale as Windows does.
    public var deviceScale: UInt32

    public init(width: UInt32, height: UInt32, desktopScale: UInt32, deviceScale: UInt32) {
        self.width = width
        self.height = height
        self.desktopScale = desktopScale
        self.deviceScale = deviceScale
    }

    /// - Parameters:
    ///   - viewSize: the area showing the desktop, in points.
    ///   - backingScale: pixels per point of the display it is on.
    ///   - scalesInterface: the remote side can scale its interface. When it cannot (VNC), the
    ///     desktop is sized in points so its interface keeps a readable size.
    public init(display: DisplayOptions, viewSize: CGSize, backingScale: CGFloat, scalesInterface: Bool = true) {
        // Remote pixels per point: a fixed desktop is shown pixel for pixel by default.
        let base = scalesInterface ? backingScale : 1
        let density: Double
        let pixels: (Double, Double)
        switch display.resolution {
        case .fixed(let width, let height):
            density = base
            pixels = (Double(width), Double(height))
        case .fitWindow:
            density = base * Double(min(100, max(25, display.renderScale))) / 100
            pixels = ((viewSize.width * density).rounded(), (viewSize.height * density).rounded())
        }
        // The remote interface scales with the density, so it keeps its size on this screen.
        let automaticScale = Int((density * 100).rounded())
        let scale = UInt32(min(500, max(100, display.scale ?? automaticScale)))
        self.init(width: UInt32(max(200, pixels.0)) & ~1, height: UInt32(max(200, pixels.1)),
                  desktopScale: scale, deviceScale: scale >= 180 ? 180 : (scale >= 140 ? 140 : 100))
    }

    /// The size agreed at connect time is capped by the protocol (MS-RDPBCGR 2.2.1.3.2): a larger
    /// layout starts proportionally smaller and is resized once display control is up.
    public var cappedForConnect: DesktopLayout {
        let shrink = min(1, 4096 / Double(width), 2048 / Double(height))
        guard shrink < 1 else { return self }
        var capped = self
        capped.width = UInt32(Double(width) * shrink) & ~1
        capped.height = UInt32(Double(height) * shrink)
        return capped
    }
}
