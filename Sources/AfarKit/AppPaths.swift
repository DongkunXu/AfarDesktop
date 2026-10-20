import Foundation

/// Where the app keeps its data. Everything lives under one folder in Application Support,
/// and every file in it belongs to a connection or to the app as a whole.
public struct AppPaths: Sendable {
    public let root: URL
    /// Disposable data; the app empties it at launch.
    public let cache: URL

    public init(root: URL, cache: URL? = nil) {
        self.root = root
        self.cache = cache ?? root.appendingPathComponent("Cache", isDirectory: true)
    }

    /// ~/Library/Application Support/Afar Desktop and ~/Library/Caches/Afar Desktop, or the folder
    /// named by AFAR_DATA_DIR: a separate set of connections for development and screenshots.
    public static let standard: AppPaths = {
        if let custom = ProcessInfo.processInfo.environment["AFAR_DATA_DIR"], !custom.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        let files = FileManager.default
        return AppPaths(
            root: files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Afar Desktop", isDirectory: true),
            cache: files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Afar Desktop", isDirectory: true))
    }()

    /// Files copied on remote computers, downloaded so they can be pasted on this Mac.
    public var clipboardFiles: URL { cache.appendingPathComponent("Clipboard", isDirectory: true) }

    /// The saved connections.
    public var connections: URL { root.appendingPathComponent("connections.json") }
    /// One preview image per connection, replaced on every disconnect, removed with it.
    public var thumbnails: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    /// The picture chosen for the main window's background (optional, one file).
    public var backdrop: URL { root.appendingPathComponent("Backdrop.jpg") }
    /// FreeRDP's own state: one accepted certificate per host and port.
    public var engine: URL { root.appendingPathComponent("FreeRDP", isDirectory: true) }
    /// The VNC client's own state: one accepted certificate fingerprint per host and port.
    public var vnc: URL { root.appendingPathComponent("VNC", isDirectory: true) }

    /// Where a session of this protocol keeps its state.
    public func state(for remoteProtocol: RemoteProtocol) -> URL {
        switch remoteProtocol {
        case .rdp: engine
        case .vnc: vnc
        }
    }

    public func thumbnail(for id: UUID) -> URL {
        thumbnails.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// The certificate FreeRDP accepted for a host, named the way FreeRDP names it
    /// (libfreerdp/crypto/certificate_data.c).
    public func acceptedCertificate(host: String, port: UInt16, remoteProtocol: RemoteProtocol = .rdp) -> URL {
        let name = "\(host)_\(port)".lowercased()
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return Self.acceptedCertificate(named: name, in: state(for: remoteProtocol), remoteProtocol: remoteProtocol)
    }

    /// The same file, given the session's state directory (sessions know only that).
    static func acceptedCertificate(named name: String, in directory: URL, remoteProtocol: RemoteProtocol) -> URL {
        switch remoteProtocol {
        case .rdp: directory.appendingPathComponent("server", isDirectory: true).appendingPathComponent(name + ".pem")
        case .vnc: directory.appendingPathComponent("certificates", isDirectory: true).appendingPathComponent(name + ".sha256")
        }
    }
}
