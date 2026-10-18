import Foundation

/// Reads and writes `.rdp` files, the connection format of Microsoft's clients: one
/// `name:type:value` setting per line, usually saved as UTF-16 with a byte order mark.
/// Only the settings Afar Desktop understands are read; passwords are never part of the file.
public enum RDPFile {
    public enum Error: Swift.Error, Equatable {
        case unreadable
        case missingAddress
    }

    // MARK: Reading

    public static func connection(from data: Data, name: String? = nil) throws -> Connection {
        guard let text = decode(data) else { throw Error.unreadable }
        var settings: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            settings[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = String(parts[2])
        }

        guard let address = settings["full address"], !address.isEmpty else { throw Error.missingAddress }
        var connection = Connection()
        let (host, port) = Connection.splitAddress(address)
        connection.host = host
        connection.port = port ?? settings["server port"].flatMap(UInt16.init) ?? 3389
        connection.name = name ?? ""

        if let username = settings["username"] {
            if let slash = username.firstIndex(of: "\\") {
                connection.domain = String(username[..<slash])
                connection.username = String(username[username.index(after: slash)...])
            } else {
                connection.username = username
            }
        }
        if let domain = settings["domain"], !domain.isEmpty { connection.domain = domain }

        let dynamic = settings["dynamic resolution"] != "0"
        if !dynamic, let width = settings["desktopwidth"].flatMap(Int.init),
           let height = settings["desktopheight"].flatMap(Int.init), width > 0, height > 0 {
            connection.display.resolution = .fixed(width: width, height: height)
        }
        connection.display.startFullScreen = settings["screen mode id"] == "2"
        connection.audio = (settings["audiomode"] ?? "0") == "0"
        connection.clipboard = settings["redirectclipboard"] != "0"

        if let gatewayHost = settings["gatewayhostname"], !gatewayHost.isEmpty,
           settings["gatewayusagemethod"] != "0", settings["gatewayusagemethod"] != "4" {
            let (host, port) = Connection.splitAddress(gatewayHost)
            connection.gateway = Gateway(host: host, port: port ?? 443)
        }
        return connection
    }

    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        // UTF-16LE without a mark: every other byte of ASCII text is zero.
        if data.count >= 2, data[data.startIndex + 1] == 0 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Writing

    /// The file as Windows writes it: UTF-16LE with a byte order mark, CRLF line endings.
    public static func data(for connection: Connection) -> Data {
        var lines: [String] = []
        func add(_ name: String, _ value: String) { lines.append("\(name):s:\(value)") }
        func add(_ name: String, _ value: Int) { lines.append("\(name):i:\(value)") }

        add("full address", connection.address)
        if !connection.username.isEmpty {
            add("username", connection.domain.isEmpty ? connection.username : "\(connection.domain)\\\(connection.username)")
        }
        add("screen mode id", connection.display.startFullScreen ? 2 : 1)
        switch connection.display.resolution {
        case .fitWindow:
            add("dynamic resolution", 1)
        case .fixed(let width, let height):
            add("dynamic resolution", 0)
            add("desktopwidth", width)
            add("desktopheight", height)
        }
        add("session bpp", 32)
        add("audiomode", connection.audio ? 0 : 2)
        add("redirectclipboard", connection.clipboard ? 1 : 0)
        add("prompt for credentials", 0)
        add("authentication level", 2)
        if let gateway = connection.gateway {
            add("gatewayhostname", gateway.port == 443 ? gateway.host : "\(gateway.host):\(gateway.port)")
            add("gatewayusagemethod", 1)
            add("gatewaycredentialssource", 0)
            add("promptcredentialonce", gateway.usesComputerCredentials ? 1 : 0)
        }

        var data = Data([0xFF, 0xFE])
        data.append((lines.joined(separator: "\r\n") + "\r\n").data(using: .utf16LittleEndian)!)
        return data
    }
}
