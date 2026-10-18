@testable import AfarKit
import Foundation
import Testing

private func utf16File(_ lines: [String]) -> Data {
    var data = Data([0xFF, 0xFE])
    data.append(lines.joined(separator: "\r\n").data(using: .utf16LittleEndian)!)
    return data
}

@Test func readsWindowsFile() throws {
    let data = utf16File([
        "screen mode id:i:2", "full address:s:pc.example:3390", "username:s:CORP\\alice",
        "dynamic resolution:i:0", "desktopwidth:i:1920", "desktopheight:i:1080",
        "audiomode:i:2", "redirectclipboard:i:1", "gatewayhostname:s:gw.example", "gatewayusagemethod:i:1",
    ])
    let connection = try RDPFile.connection(from: data, name: "Work PC")
    #expect(connection.name == "Work PC")
    #expect(connection.host == "pc.example" && connection.port == 3390)
    #expect(connection.domain == "CORP" && connection.username == "alice")
    #expect(connection.display.resolution == .fixed(width: 1920, height: 1080))
    #expect(connection.display.startFullScreen)
    #expect(!connection.audio && connection.clipboard)
    #expect(connection.gateway == Gateway(host: "gw.example", port: 443))
}

@Test func readsUTF8AndServerPort() throws {
    let data = Data("full address:s:10.0.0.2\nserver port:i:4000\n".utf8)
    let connection = try RDPFile.connection(from: data)
    #expect(connection.host == "10.0.0.2" && connection.port == 4000)
    #expect(connection.display.resolution == .fitWindow)
}

@Test func rejectsFileWithoutAddress() {
    #expect(throws: RDPFile.Error.missingAddress) { try RDPFile.connection(from: Data("username:s:x".utf8)) }
}

@Test func writtenFileReadsBack() throws {
    var original = Connection(name: "Lab", host: "fe80::1", port: 3391, username: "bob", domain: "LAB")
    original.display.resolution = .fixed(width: 2560, height: 1440)
    original.gateway = Gateway(host: "gw.example", port: 8443, username: "bob")
    let copy = try RDPFile.connection(from: RDPFile.data(for: original), name: "Lab")
    #expect(copy.host == original.host && copy.port == original.port)
    #expect(copy.username == "bob" && copy.domain == "LAB")
    #expect(copy.display.resolution == original.display.resolution)
    #expect(copy.gateway?.host == "gw.example" && copy.gateway?.port == 8443)
}

@Test func splitsAddresses() {
    #expect(Connection.splitAddress("host") == ("host", nil))
    #expect(Connection.splitAddress("host:3390") == ("host", 3390))
    #expect(Connection.splitAddress("[fe80::1]:3390") == ("fe80::1", 3390))
    #expect(Connection.splitAddress("fe80::1") == ("fe80::1", nil))
}
