// Development tool: connects without a window, prints what happens and saves a frame.
//
//   afar-probe <host> [port] [--user NAME] [--seconds N] [--resize WxH[@SCALE]] [--png PATH]
//              [--copy TEXT] [--offer FILE]... [--fetch DIR] [--click X,Y] [--stats] [--420]
//
// The password is read from standard input (one line), so it never appears in the process list.
// Certificates are accepted for this run only and printed. --copy offers TEXT and --offer files on
// the remote clipboard; whatever the remote side copies is printed, and files it copies are
// downloaded into --fetch DIR. --click clicks the remote desktop at X,Y two seconds after
// connecting. --stats prints the session's statistics every second; --420 offers H.264 4:2:0 only.

import AfarKit
import Foundation
import IOSurface
import ImageIO
import UniformTypeIdentifiers

struct Options {
    var host = ""
    var port: UInt16 = 3389
    var user: String?
    var seconds = 8.0
    var resize: PixelSize?
    var resizeScale: UInt32 = 100
    var png: URL?
    var copy: String?
    var offer: [URL] = []
    var fetch: URL?
    var click: (Int32, Int32)?
    var stats = false
    var fullColor = true
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    func value() -> String {
        guard let next = args.popFirst() else { fail("missing value") }
        return next
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--user": options.user = value()
        case "--seconds": options.seconds = Double(value()) ?? options.seconds
        case "--png": options.png = URL(fileURLWithPath: value())
        case "--copy": options.copy = value()
        case "--offer": options.offer.append(URL(fileURLWithPath: value()))
        case "--fetch": options.fetch = URL(fileURLWithPath: value())
        case "--stats": options.stats = true
        case "--420": options.fullColor = false
        case "--click":
            let parts = value().split(separator: ",").compactMap { Int32($0) }
            guard parts.count == 2 else { fail("--click expects X,Y") }
            options.click = (parts[0], parts[1])
        case "--resize":
            let spec = value().split(separator: "@")
            let parts = spec[0].split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { fail("--resize expects WIDTHxHEIGHT[@SCALE]") }
            options.resize = PixelSize(width: parts[0], height: parts[1])
            if spec.count > 1, let scale = UInt32(spec[1]) { options.resizeScale = scale }
        default:
            if options.host.isEmpty { options.host = arg } else if let port = UInt16(arg) { options.port = port }
        }
    }
    if options.host.isEmpty {
        fail("usage: afar-probe <host> [port] [--user NAME] [--seconds N] [--resize WxH[@SCALE]] [--png PATH] [--copy TEXT] [--offer FILE]... [--fetch DIR] [--click X,Y] [--stats] [--420]")
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func log(_ message: String) {
    let stamp = String(format: "%7.2f", Date().timeIntervalSince(start))
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

let start = Date()

@MainActor
final class Probe: RDPSessionDelegate {
    let options: Options
    let password: String?
    let session = RDPSession()
    var surface: IOSurface?
    var frames = 0
    var finished = false

    init(options: Options, password: String?) {
        self.options = options
        self.password = password
    }

    func run() {
        session.delegate = self
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("afar-probe")
        do {
            try session.connect(.init(host: options.host, port: options.port, username: options.user,
                                      password: password, width: 1280, height: 800, fullColor: options.fullColor, audio: false,
                                      configDirectory: config))
        } catch {
            fail("connect failed: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { [self] in
            log("time is up after \(frames) frame updates")
            if let surface, let png = options.png { save(surface, to: png) }
            session.disconnect()
        }
        while !finished { RunLoop.main.run(mode: .default, before: .now + 0.1) }
        session.close()
    }

    func session(_ session: RDPSession, stateChanged state: RDPSession.State) {
        log("state: \(state)")
        if case .disconnected = state { finished = true }
        if state == .connected, let text = options.copy {
            log("offering clipboard text")
            session.offerClipboard(.text(text))
        }
        if state == .connected, let (x, y) = options.click {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                log("clicking \(x),\(y)")
                session.sendMouseMove(x: x, y: y)
                session.sendMouseButton(.left, down: true, x: x, y: y)
                session.sendMouseButton(.left, down: false, x: x, y: y)
            }
        }
        if state == .connected, options.stats { printStatistics(after: session.statistics()) }
        if state == .connected, !options.offer.isEmpty {
            log("offering \(options.offer.count) file(s)")
            session.offerFiles(options.offer)
        }
    }

    func session(_ session: RDPSession, surfaceChanged surface: IOSurface, size: PixelSize) {
        log("desktop \(size.width)x\(size.height)")
        self.surface = surface
    }

    func session(_ session: RDPSession, frameUpdated surface: IOSurface) {
        self.surface = surface
        frames += 1
        if frames == 1 { log("first frame") }
    }

    func sessionDisplayControlReady(_ session: RDPSession) {
        log("display control ready")
        if let size = options.resize {
            let scale = options.resizeScale
            log("requesting \(size.width)x\(size.height) at \(scale)%")
            session.requestLayout(width: UInt32(size.width), height: UInt32(size.height), desktopScale: scale,
                                  deviceScale: scale >= 180 ? 180 : (scale >= 140 ? 140 : 100))
        }
    }

    func session(_ session: RDPSession, verify certificate: CertificateInfo,
                 decide: @escaping @Sendable (CertificateDecision) -> Void) {
        log("certificate \(certificate.commonName) \(certificate.fingerprint)\(certificate.changed ? " (changed)" : "")")
        decide(.acceptOnce)
    }

    func session(_ session: RDPSession, credentialsFor request: CredentialRequest,
                 provide: @escaping @Sendable (Credentials?) -> Void) {
        log("credentials requested for \(request.username.isEmpty ? "?" : request.username); none available")
        provide(nil)
    }

    func session(_ session: RDPSession, cursorCreated cursor: CursorImage) {}
    func session(_ session: RDPSession, cursorReleased id: UInt64) {}
    func session(_ session: RDPSession, cursorChanged cursor: RemoteCursor) {}

    func session(_ session: RDPSession, clipboardReceived content: ClipboardContent) {
        switch content {
        case .text(let text): log("remote clipboard text: \(text.prefix(80).debugDescription)")
        case .image(let image): log("remote clipboard image \(image.width)x\(image.height)")
        }
    }

    func session(_ session: RDPSession, remoteFilesOffered count: Int, bytes: UInt64) {
        log("remote clipboard: \(count) file(s), \(bytes) bytes")
        if let directory = options.fetch { session.fetchRemoteFiles(into: directory) }
    }

    func session(_ session: RDPSession, remoteFilesProgress done: UInt64, of total: UInt64) {
        log("downloaded \(done) of \(total) bytes")
    }

    func session(_ session: RDPSession, remoteFilesFinished success: Bool) {
        log(success ? "download complete" : "download failed")
    }

    func printStatistics(after previous: RDPStatistics?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard !finished, let current = session.statistics() else { return }
            if let previous {
                let s = StatisticsSample(from: previous, to: current)
                func f(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "-" }
                log("stats \(f(s.framesPerSecond, "%.0f")) fps, ↓\(f(s.receivedBitsPerSecond / 1e6, "%.2f")) ↑\(f(s.sentBitsPerSecond / 1e6, "%.2f")) Mb/s, "
                    + "rtt \(f(s.roundTripMilliseconds, "%.0f"))±\(f(s.jitterMilliseconds, "%.0f")) ms, "
                    + "resent \(f(s.retransmittedFraction.map { $0 * 100 }, "%.2f"))%, ooo \(f(s.outOfOrderFraction.map { $0 * 100 }, "%.2f"))%, "
                    + "decode \(f(s.decodeMilliseconds, "%.2f")) ms, codec \(current.codec.map { "\($0)" } ?? "-")")
            }
            printStatistics(after: current)
        }
    }

    func save(_ surface: IOSurface, to url: URL) {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: surface.baseAddress, width: surface.width, height: surface.height,
                                      bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: space,
                                      bitmapInfo: info),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return log("could not save frame") }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        log("saved \(url.path)")
    }
}

let options = parseOptions()
let password = isatty(STDIN_FILENO) == 0 ? readLine(strippingNewline: true) : nil
MainActor.assumeIsolated {
    Probe(options: options, password: password).run()
}
