import Foundation
import Observation

/// The saved connections, persisted as JSON. Owns the files that belong to each connection:
/// deleting one also removes its preview image and, when no other connection uses them,
/// its Keychain password and the certificate accepted for its host.
@MainActor
@Observable
public final class ConnectionStore {
    public private(set) var connections: [Connection] = []
    public private(set) var loadError: String?

    public let paths: AppPaths
    public let credentials: CredentialStore

    public init(paths: AppPaths = .standard, credentials: CredentialStore = CredentialStore()) {
        self.paths = paths
        self.credentials = credentials
        load()
    }

    /// Group names in use, sorted.
    public var groups: [String] {
        Array(Set(connections.map(\.group).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func connection(_ id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    // MARK: Changes

    public func add(_ connection: Connection) {
        connections.append(connection)
        save()
    }

    public func update(_ connection: Connection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return add(connection) }
        let old = connections[index]
        connections[index] = connection
        save()
        // A password stays with the computer and account it was saved for.
        if CredentialStore.Key(old) != CredentialStore.Key(connection)
            || CredentialStore.Key(gatewayOf: old) != CredentialStore.Key(gatewayOf: connection) {
            releasePassword(of: old)
        }
        if (old.host.lowercased(), old.port) != (connection.host.lowercased(), connection.port) {
            releaseCertificate(of: old)
        }
    }

    public func duplicate(_ id: UUID) -> Connection? {
        guard var copy = connection(id) else { return nil }
        copy.id = UUID()
        copy.name = copy.displayName + " " + String(localized: "copy", comment: "Suffix for a duplicated connection")
        copy.created = Date()
        copy.lastConnected = nil
        add(copy)
        return copy
    }

    public func delete(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let removed = connections.remove(at: index)
        save()
        try? FileManager.default.removeItem(at: paths.thumbnail(for: id))
        releasePassword(of: removed)
        releaseCertificate(of: removed)
    }

    public func markConnected(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].lastConnected = Date()
        save()
    }

    /// Removes the connection's passwords (computer and gateway) once no saved connection uses them.
    private func releasePassword(of connection: Connection) {
        let inUse = Set(connections.flatMap { [CredentialStore.Key($0), CredentialStore.Key(gatewayOf: $0)].compactMap { $0 } })
        for key in [CredentialStore.Key(connection), CredentialStore.Key(gatewayOf: connection)].compactMap({ $0 })
        where !inUse.contains(key) {
            try? credentials.removePassword(for: key)
        }
    }

    /// Removes the accepted certificate once no saved connection points at that host and port.
    private func releaseCertificate(of connection: Connection) {
        let host = connection.host.lowercased()
        guard !connections.contains(where: { $0.host.lowercased() == host && $0.port == connection.port }) else { return }
        try? FileManager.default.removeItem(at: paths.acceptedCertificate(host: connection.host, port: connection.port))
    }

    // MARK: Persistence

    private struct File: Codable {
        var version = 1
        var connections: [Connection]
    }

    private func load() {
        guard let data = try? Data(contentsOf: paths.connections) else { return }
        do {
            connections = try Self.decoder.decode(File.self, from: data).connections
        } catch {
            // Keep the unreadable file for the user instead of overwriting it on the next save.
            let backup = paths.connections.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: paths.connections, to: backup)
            loadError = error.localizedDescription
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(File(connections: connections))
            try data.write(to: paths.connections, options: .atomic)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
