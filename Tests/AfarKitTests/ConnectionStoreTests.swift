@testable import AfarKit
import Foundation
import Testing

@MainActor
struct ConnectionStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AfarKitTests-\(UUID().uuidString)")

    // Connections without a user name never touch the Keychain.
    func makeStore() -> ConnectionStore {
        ConnectionStore(paths: AppPaths(root: root))
    }

    @Test func savesAndReloads() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore()
        store.add(Connection(name: "Office", host: "office.example", group: "Work"))
        store.add(Connection(host: "10.0.0.5", port: 3390))

        let reloaded = makeStore()
        #expect(reloaded.connections.map(\.displayName) == ["Office", "10.0.0.5:3390"])
        #expect(reloaded.groups == ["Work"])
    }

    @Test func deleteRemovesItsFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore()
        let a = Connection(host: "Shared.example")
        let b = Connection(host: "shared.example")
        store.add(a)
        store.add(b)

        let paths = AppPaths(root: root)
        let certificate = paths.acceptedCertificate(host: "shared.example", port: 3389)
        try FileManager.default.createDirectory(at: certificate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pem".utf8).write(to: certificate)
        try FileManager.default.createDirectory(at: paths.thumbnails, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: paths.thumbnail(for: a.id))

        store.delete(a.id)
        #expect(!FileManager.default.fileExists(atPath: paths.thumbnail(for: a.id).path))
        #expect(FileManager.default.fileExists(atPath: certificate.path), "still used by the other connection")

        store.delete(b.id)
        #expect(!FileManager.default.fileExists(atPath: certificate.path))
    }

    @Test func unreadableFileIsKeptAside() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: paths.connections)

        let store = makeStore()
        #expect(store.connections.isEmpty)
        #expect(store.loadError != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains { $0.hasPrefix("connections.unreadable-") })
    }
}

@Test func decodingFillsMissingFields() throws {
    let json = #"{"id":"7C2E0D2A-1C55-4B7B-9A55-3D3F0D9E2B11","host":"pc"}"#
    let connection = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
    #expect(connection.port == 3389)
    #expect(connection.display == DisplayOptions())
    #expect(connection.displayName == "pc")
}

@Test func certificateFileNameMatchesFreeRDP() {
    let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/x"))
    #expect(paths.acceptedCertificate(host: "Studio-PC", port: 3389).lastPathComponent == "studio-pc_3389.pem")
    #expect(paths.acceptedCertificate(host: "fe80::1", port: 3389).lastPathComponent == "fe80..1_3389.pem")
}
