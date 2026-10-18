@testable import AfarKit
import CoreGraphics
import Testing

@Test func retinaWindowUsesPixelsAndDoubleScale() {
    let layout = DesktopLayout(display: DisplayOptions(), viewSize: CGSize(width: 1201, height: 800), backingScale: 2)
    #expect(layout == DesktopLayout(width: 2402, height: 1600, desktopScale: 200, deviceScale: 180))
}

@Test func halfRenderScaleUsesPoints() {
    let display = DisplayOptions(renderScale: 50)
    let layout = DesktopLayout(display: display, viewSize: CGSize(width: 1281, height: 800), backingScale: 2)
    #expect(layout == DesktopLayout(width: 1280, height: 800, desktopScale: 100, deviceScale: 100))
}

@Test func renderScaleKeepsInterfaceSize() {
    let display = DisplayOptions(renderScale: 67)
    let layout = DesktopLayout(display: display, viewSize: CGSize(width: 1512, height: 945), backingScale: 2)
    #expect(layout == DesktopLayout(width: 2026, height: 1266, desktopScale: 134, deviceScale: 100))
}

@Test func renderScaleNeverShrinksInterfaceBelowNormal() {
    let display = DisplayOptions(renderScale: 80)
    let layout = DesktopLayout(display: display, viewSize: CGSize(width: 1000, height: 600), backingScale: 1)
    #expect(layout == DesktopLayout(width: 800, height: 480, desktopScale: 100, deviceScale: 100))
}

@Test func fixedSizeAndManualScale() {
    let display = DisplayOptions(resolution: .fixed(width: 1920, height: 1080), scale: 150)
    let layout = DesktopLayout(display: display, viewSize: CGSize(width: 10, height: 10), backingScale: 2)
    #expect(layout == DesktopLayout(width: 1920, height: 1080, desktopScale: 150, deviceScale: 140))
}

@Test func connectSizeIsCapped() {
    let big = DesktopLayout(width: 5120, height: 2880, desktopScale: 200, deviceScale: 180).cappedForConnect
    #expect(big.width <= 4096 && big.height <= 2048)
    #expect(big.width % 2 == 0)
    let small = DesktopLayout(width: 1600, height: 1000, desktopScale: 100, deviceScale: 100)
    #expect(small.cappedForConnect == small)
}
