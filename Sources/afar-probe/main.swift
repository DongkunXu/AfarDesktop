// Development tool: connects without a window, prints what happens and saves a frame.
//
//   afar-probe <host> [port] [--vnc] [--user NAME] [--seconds N] [--resize WxH[@SCALE]] [--png PATH]
//              [--copy TEXT] [--offer FILE]... [--fetch DIR] [--click X,Y] [--type TEXT] [--stats] [--lossy]
//   afar-probe <host> [port] --detect
//
// The password is read from standard input (one line), so it never appears in the process list.
// Certificates are accepted for this run only and printed. --copy offers TEXT and --offer files on
// the remote clipboard; whatever the remote side copies is printed, and files it copies are
// downloaded into --fetch DIR. --click clicks the remote desktop at X,Y two seconds after
// connecting, --type types ASCII TEXT after that. --stats prints the session's statistics every second;
// --lossy offers reduced colour detail (H.264 4:2:0 for RDP, JPEG for VNC). --vnc speaks VNC, with
// the password alone when no --user is given. --detect only reports which protocol answers.

import AfarKit
import Foundation
import IOSurface
import ImageIO
import UniformTypeIdentifiers

struct Options {
    var host = ""
    var remoteProtocol = RemoteProtocol.rdp
    var port: UInt16?
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
    var type: String?
    var detect = false
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
        case "--lossy": options.fullColor = false
        case "--vnc": options.remoteProtocol = .vnc
        case "--detect": options.detect = true
        case "--type": options.type = value()
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
        fail("usage: afar-probe <host> [port] [--user NAME] [--seconds N] [--resize WxH[@SCALE]] [--png PATH] [--copy TEXT] [--offer FILE]... [--fetch DIR] [--click X,Y] [--type TEXT] [--stats] [--lossy] [--vnc]")
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
final class Probe: RemoteSessionDelegate {
    let options: Options
    let password: String?
    let session: any RemoteSession
    var surface: IOSurface?
    var frames = 0
    var finished = false

    init(options: Options, password: String?) {
        self.options = options
        self.password = password
        session = options.remoteProtocol.makeSession()
    }

    func run() {
        session.delegate = self
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("afar-probe")
        let layout = DesktopLayout(width: 1280, height: 800, desktopScale: 100, deviceScale: 100)
        do {
            try session.connect(.init(host: options.host, port: options.remoteProtocol.port(fromAddress: options.port),
                                      username: options.user, password: password, layout: layout,
                                      fullColor: options.fullColor, audio: false, stateDirectory: state))
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

    func session(_ session: any RemoteSession, stateChanged state: SessionState) {
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
        if state == .connected, let text = options.type {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                log("typing \(text.debugDescription)")
                for code in text.compactMap(Self.keyCode) {
                    session.sendKey(code, down: true)
                    session.sendKey(code, down: false)
                }
            }
        }
        if state == .connected, !options.offer.isEmpty {
            log("offering \(options.offer.count) file(s)")
            session.offerFiles(options.offer)
        }
    }

    func session(_ session: any RemoteSession, surfaceChanged surface: IOSurface, size: PixelSize) {
        log("desktop \(size.width)x\(size.height)")
        self.surface = surface
    }

    func session(_ session: any RemoteSession, frameUpdated surface: IOSurface) {
        self.surface = surface
        frames += 1
        if frames == 1 { log("first frame") }
    }

    func sessionCanResize(_ session: any RemoteSession) {
        log("display control ready")
        if let size = options.resize {
            let scale = options.resizeScale
            log("requesting \(size.width)x\(size.height) at \(scale)%")
            session.requestLayout(DesktopLayout(width: UInt32(size.width), height: UInt32(size.height), desktopScale: scale,
                                                deviceScale: scale >= 180 ? 180 : (scale >= 140 ? 140 : 100)))
        }
    }

    func session(_ session: any RemoteSession, verify certificate: CertificateInfo,
                 decide: @escaping @Sendable (CertificateDecision) -> Void) {
        log("certificate \(certificate.commonName) \(certificate.fingerprint)\(certificate.changed ? " (changed)" : "")")
        decide(.acceptOnce)
    }

    func session(_ session: any RemoteSession, credentialsFor request: CredentialRequest,
                 provide: @escaping @Sendable (Credentials?) -> Void) {
        log("credentials requested (\(request.needsUsername ? "user name and password" : "password")); none available")
        provide(nil)
    }

    func session(_ session: any RemoteSession, cursorCreated cursor: CursorImage) {
        log("cursor \(cursor.width)x\(cursor.height), hotspot \(Int(cursor.hotspot.x)),\(Int(cursor.hotspot.y))")
    }
    func session(_ session: any RemoteSession, cursorReleased id: UInt64) {}
    func session(_ session: any RemoteSession, cursorChanged cursor: RemoteCursor) {}

    func session(_ session: any RemoteSession, clipboardReceived content: ClipboardContent) {
        switch content {
        case .text(let text): log("remote clipboard text: \(text.prefix(80).debugDescription)")
        case .image(let image): log("remote clipboard image \(image.width)x\(image.height)")
        }
    }

    func session(_ session: any RemoteSession, remoteFilesOffered count: Int, bytes: UInt64) {
        log("remote clipboard: \(count) file(s), \(bytes) bytes")
        if let directory = options.fetch { session.fetchRemoteFiles(into: directory) }
    }

    func session(_ session: any RemoteSession, remoteFilesProgress done: UInt64, of total: UInt64) {
        log("downloaded \(done) of \(total) bytes")
    }

    func session(_ session: any RemoteSession, remoteFilesFinished success: Bool) {
        log(success ? "download complete" : "download failed")
    }

    func printStatistics(after previous: RemoteStatistics?) {
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

    /// US-layout key codes for lowercase letters, digits, space and return (enough for tests).
    static func keyCode(_ character: Character) -> UInt16? {
        let codes: [Character: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
            "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
            "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
            "0": 0x1D, " ": 0x31, "\n": 0x24, "-": 0x1B, ".": 0x2F,
        ]
        return codes[character]
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
if options.detect {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached { // the main thread waits below
        let result = await ProtocolDetector.detect(host: options.host, port: options.port)
        print(result.map { "\($0.remoteProtocol.name) on port \($0.port)" } ?? "no answer")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}
let password = isatty(STDIN_FILENO) == 0 ? readLine(strippingNewline: true) : nil
MainActor.assumeIsolated {
    Probe(options: options, password: password).run()
}
