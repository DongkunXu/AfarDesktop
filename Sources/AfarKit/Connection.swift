import Foundation

/// A saved remote computer. Secrets never live here: passwords are in the Keychain
/// (see `CredentialStore`).
public struct Connection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var domain: String
    public var group: String
    public var display: DisplayOptions
    public var commandKey: CommandKeyMapping
    public var audio: Bool
    public var clipboard: Bool
    public var gateway: Gateway?
    public var created: Date
    public var lastConnected: Date?

    public init(id: UUID = UUID(), name: String = "", host: String = "", port: UInt16 = 3389,
                username: String = "", domain: String = "", group: String = "",
                display: DisplayOptions = DisplayOptions(), commandKey: CommandKeyMapping = .control,
                audio: Bool = true, clipboard: Bool = true, gateway: Gateway? = nil,
                created: Date = Date(), lastConnected: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.group = group
        self.display = display
        self.commandKey = commandKey
        self.audio = audio
        self.clipboard = clipboard
        self.gateway = gateway
        self.created = created
        self.lastConnected = lastConnected
    }

    /// The name shown in lists and window titles.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? address : trimmed
    }

    /// How the connection's password is labelled in Keychain Access.
    public var keychainLabel: String { "\(displayName) (Afar Desktop)" }

    /// host, or host:port when the port is not the default.
    public var address: String {
        let shown = host.contains(":") ? "[\(host)]" : host
        return port == 3389 ? shown : "\(shown):\(port)"
    }

    /// Splits "host", "host:port", "[v6]:port" or a bare IPv6 address; the port is nil when absent.
    public static func splitAddress(_ address: String) -> (host: String, port: UInt16?) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) : nil)
        }
        if trimmed.filter({ $0 == ":" }).count == 1, let index = trimmed.lastIndex(of: ":"),
           let port = UInt16(trimmed[trimmed.index(after: index)...]) {
            return (String(trimmed[..<index]), port)
        }
        return (trimmed, nil)
    }


    // Decoding tolerates missing keys so files written by older versions keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Connection()
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? defaults.port
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? defaults.domain
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? defaults.group
        display = try c.decodeIfPresent(DisplayOptions.self, forKey: .display) ?? defaults.display
        commandKey = try c.decodeIfPresent(CommandKeyMapping.self, forKey: .commandKey) ?? defaults.commandKey
        audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? defaults.audio
        clipboard = try c.decodeIfPresent(Bool.self, forKey: .clipboard) ?? defaults.clipboard
        gateway = try c.decodeIfPresent(Gateway.self, forKey: .gateway)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? defaults.created
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
    }
}

/// A Remote Desktop Gateway the connection goes through.
public struct Gateway: Codable, Hashable, Sendable {
    public var host: String
    public var port: UInt16
    /// Empty: sign in to the gateway with the computer's credentials.
    public var username: String

    public init(host: String, port: UInt16 = 443, username: String = "") {
        self.host = host
        self.port = port
        self.username = username
    }

    public var usesComputerCredentials: Bool { username.isEmpty }
}

public struct DisplayOptions: Codable, Hashable, Sendable {
    public enum Resolution: Codable, Hashable, Sendable {
        /// The remote desktop follows the window size.
        case fitWindow
        /// A fixed desktop size in pixels; the window scales it.
        case fixed(width: Int, height: Int)
    }

    public var resolution: Resolution
    /// For window-sized desktops: the remote pixels as a percentage of the screen pixels the
    /// window covers. Below 100 the remote side draws fewer pixels (less to encode and send) and
    /// the window scales the image up; the remote interface keeps its size.
    public var renderScale: Int
    /// Remote UI scale in percent; nil picks one that matches this Mac.
    public var scale: Int?
    /// H.264 with full colour resolution (4:4:4) for sharp coloured text; off asks for 4:2:0,
    /// which halves the colour detail and the data.
    public var fullColor: Bool
    public var startFullScreen: Bool

    /// The render scales offered in the app.
    public static let renderScales = [100, 80, 67, 50]

    public init(resolution: Resolution = .fitWindow, renderScale: Int = 100, scale: Int? = nil,
                fullColor: Bool = true, startFullScreen: Bool = false) {
        self.resolution = resolution
        self.renderScale = renderScale
        self.scale = scale
        self.fullColor = fullColor
        self.startFullScreen = startFullScreen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DisplayOptions()
        resolution = try c.decodeIfPresent(Resolution.self, forKey: .resolution) ?? defaults.resolution
        renderScale = try c.decodeIfPresent(Int.self, forKey: .renderScale) ?? defaults.renderScale
        scale = try c.decodeIfPresent(Int.self, forKey: .scale)
        fullColor = try c.decodeIfPresent(Bool.self, forKey: .fullColor) ?? defaults.fullColor
        startFullScreen = try c.decodeIfPresent(Bool.self, forKey: .startFullScreen) ?? defaults.startFullScreen
    }
}

public enum CommandKeyMapping: String, Codable, CaseIterable, Sendable {
    /// ⌘ is the Windows / Super key, ⌃ is Ctrl.
    case windowsKey
    /// ⌘ acts as Ctrl, so ⌘C / ⌘V copy and paste as on the Mac.
    case control
}
