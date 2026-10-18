import AfarKit
import AppKit
import Carbon.HIToolbox

/// Shows the remote desktop and forwards keyboard and mouse input to it.
///
/// The desktop image is an IOSurface shared with the engine and set as the layer's contents,
/// so drawing costs one composite per frame and no copies on the main thread.
final class SessionView: NSView {
    weak var session: RDPSession?
    var commandKey: CommandKeyMapping = .windowsKey
    /// Fixed-size desktops keep their proportions; window-sized ones fill the view.
    var preservesAspectRatio = false {
        didSet { layer?.contentsGravity = preservesAspectRatio ? .resizeAspect : .resize }
    }
    /// Called when the view wants a different remote desktop size (window resized, moved to
    /// another display).
    var onLayoutChange: (() -> Void)?

    private(set) var remoteSize = PixelSize(width: 0, height: 0)
    private var cursors: [UInt64: NSCursor] = [:]
    private var cursorImages: [UInt64: CursorImage] = [:]
    private var currentCursor: NSCursor = .arrow
    private var pressedModifiers: Set<UInt16> = []
    private var scrollRemainder = CGPoint.zero
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Image

    func show(surface: IOSurface, size: PixelSize) {
        remoteSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
        refreshCursorScale()
    }

    func show(frame surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
    }

    func clear() {
        layer?.contents = nil
    }

    /// The current image, for the connection's preview thumbnail.
    func snapshot(maxWidth: CGFloat) -> CGImage? {
        guard let surface = layer?.contents as! IOSurface?, surface.width > 0 else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let full = CGContext(data: surface.baseAddress, width: surface.width, height: surface.height,
                                   bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: space,
                                   bitmapInfo: info)?.makeImage() else { return nil }
        let scale = min(1, maxWidth / CGFloat(surface.width))
        let width = Int(CGFloat(surface.width) * scale), height = Int(CGFloat(surface.height) * scale)
        guard let small = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: space, bitmapInfo: info) else { return nil }
        small.interpolationQuality = .high
        small.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return small.makeImage()
    }

    // MARK: Geometry

    /// The size in pixels this view covers on its display.
    var backingPixelSize: PixelSize {
        let backing = convertToBacking(bounds).size
        return PixelSize(width: Int(backing.width.rounded()), height: Int(backing.height.rounded()))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayoutChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        refreshCursorScale()
        onLayoutChange?()
    }

    /// Where the desktop image is drawn inside the view.
    private var imageRect: CGRect {
        guard preservesAspectRatio, remoteSize.width > 0, remoteSize.height > 0 else { return bounds }
        let scale = min(bounds.width / CGFloat(remoteSize.width), bounds.height / CGFloat(remoteSize.height))
        let size = CGSize(width: CGFloat(remoteSize.width) * scale, height: CGFloat(remoteSize.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Maps a point in this view to a remote desktop pixel.
    private func remotePoint(_ event: NSEvent) -> (Int32, Int32) {
        let local = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, remoteSize.width > 0 else { return (0, 0) }
        let x = (local.x - rect.minX) / rect.width * CGFloat(remoteSize.width)
        let y = (1 - (local.y - rect.minY) / rect.height) * CGFloat(remoteSize.height)
        return (Int32(min(max(0, x), CGFloat(remoteSize.width - 1))),
                Int32(min(max(0, y), CGFloat(remoteSize.height - 1))))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        button(.left, down: true, event)
    }
    override func mouseUp(with event: NSEvent) { button(.left, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { button(.right, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { button(.right, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { otherButton(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { otherButton(event, down: false) }

    private func move(_ event: NSEvent) {
        let (x, y) = remotePoint(event)
        session?.sendMouseMove(x: x, y: y)
    }

    private func button(_ button: MouseButton, down: Bool, _ event: NSEvent) {
        let (x, y) = remotePoint(event)
        session?.sendMouseButton(button, down: down, x: x, y: y)
    }

    private func otherButton(_ event: NSEvent, down: Bool) {
        switch event.buttonNumber {
        case 2: button(.middle, down: down, event)
        case 3: button(.back, down: down, event)
        case 4: button(.forward, down: down, event)
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let (x, y) = remotePoint(event)
        // Wheel mice report lines; trackpads and Magic Mouse report points. One wheel notch is
        // 120 units in RDP, about three lines.
        let perUnit: CGFloat = event.hasPreciseScrollingDeltas ? 4 : 40
        let dx = -event.scrollingDeltaX * perUnit + scrollRemainder.x
        let dy = event.scrollingDeltaY * perUnit + scrollRemainder.y
        let sendX = dx.rounded(.towardZero), sendY = dy.rounded(.towardZero)
        scrollRemainder = CGPoint(x: dx - sendX, y: dy - sendY)
        if sendX != 0 || sendY != 0 {
            session?.sendWheel(vertical: Int32(sendY), horizontal: Int32(sendX), x: x, y: y)
        }
        if event.phase == .ended || event.momentumPhase == .ended { scrollRemainder = .zero }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        session?.sendKey(event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        session?.sendKey(event.keyCode, down: false)
    }

    /// Key combinations normally go to the remote computer. These few stay with the Mac.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let reserved: Bool = switch (flags.subtracting([.function, .numericPad]), key) {
        case ([.command], "q"), ([.command], "h"), ([.command, .option], "h"),
             ([.command], "m"), ([.command], "`"), ([.command, .control], "f"),
             ([.command, .shift], "`"), ([.command], ","):
            true
        default:
            false
        }
        if reserved { return false }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        if code == UInt16(kVK_CapsLock) {
            // macOS reports Caps Lock once per toggle; the remote side toggles on a key press.
            session?.sendKey(code, down: true)
            session?.sendKey(code, down: false)
            return
        }
        guard let mask = Self.modifierMasks[code] else { return }
        let down = event.modifierFlags.rawValue & mask != 0
        let mapped = mapModifier(code)
        if down { pressedModifiers.insert(mapped) } else { pressedModifiers.remove(mapped) }
        session?.sendKey(mapped, down: down)
    }

    /// ⌘ may stand in for Ctrl, depending on the connection's setting.
    private func mapModifier(_ code: UInt16) -> UInt16 {
        guard commandKey == .control else { return code }
        switch Int(code) {
        case kVK_Command: return UInt16(kVK_Control)
        case kVK_RightCommand: return UInt16(kVK_RightControl)
        default: return code
        }
    }

    /// Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) that tell left and right keys apart.
    private static let modifierMasks: [UInt16: UInt] = [
        UInt16(kVK_Shift): 0x02, UInt16(kVK_RightShift): 0x04,
        UInt16(kVK_Control): 0x01, UInt16(kVK_RightControl): 0x2000,
        UInt16(kVK_Option): 0x20, UInt16(kVK_RightOption): 0x40,
        UInt16(kVK_Command): 0x08, UInt16(kVK_RightCommand): 0x10,
    ]

    /// Sends key-ups for everything still held, e.g. when the window loses focus mid-shortcut.
    func releaseInput() {
        pressedModifiers.removeAll()
        session?.releaseAllInput()
    }

    // MARK: Cursor

    func addCursor(_ image: CursorImage) {
        cursorImages[image.id] = image
        cursors[image.id] = makeCursor(image)
    }

    func removeCursor(_ id: UInt64) {
        cursorImages[id] = nil
        cursors[id] = nil
    }

    func setCursor(_ cursor: RemoteCursor) {
        switch cursor {
        case .system: currentCursor = .arrow
        case .hidden: currentCursor = Self.hiddenCursor
        case .custom(let id): currentCursor = cursors[id] ?? .arrow
        }
        if let window, window.isKeyWindow,
           bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            currentCursor.set()
        }
    }

    private func refreshCursorScale() {
        for (id, image) in cursorImages { cursors[id] = makeCursor(image) }
    }

    /// Remote cursor images are in remote pixels; shown at the same size as the desktop around them.
    private func makeCursor(_ image: CursorImage) -> NSCursor {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: image.bgra as CFData),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: image.width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return .arrow }
        let rect = imageRect
        let pixelsPerPoint = remoteSize.width > 0 && rect.width > 0 ? CGFloat(remoteSize.width) / rect.width : 1
        let size = NSSize(width: CGFloat(image.width) / pixelsPerPoint, height: CGFloat(image.height) / pixelsPerPoint)
        let hotspot = NSPoint(x: image.hotspot.x / pixelsPerPoint, y: image.hotspot.y / pixelsPerPoint)
        return NSCursor(image: NSImage(cgImage: cg, size: size), hotSpot: hotspot)
    }

    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
}
