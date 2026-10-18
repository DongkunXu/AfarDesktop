@testable import AfarKit
import Foundation
import Testing

@Test func flattensFoldersWithRelativeNames() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileList-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("2026"), withIntermediateDirectories: true)
    try Data(count: 5).write(to: folder.appendingPathComponent("2026/a.jpg"))
    try Data(count: 3).write(to: root.appendingPathComponent("note.txt"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))

    let list = ClipboardFileList([folder, root.appendingPathComponent("note.txt")])
    let names = list.entries.map(\.name)
    #expect(names.first == "Photos")
    #expect(Set(names) == ["Photos", "Photos/2026", "Photos/2026/a.jpg", "note.txt"])
    #expect(names.firstIndex(of: "Photos/2026")! < names.firstIndex(of: "Photos/2026/a.jpg")!)
    #expect(list.entries.first { $0.name == "Photos/2026/a.jpg" }?.size == 5)
    #expect(list.entries.first { $0.name == "Photos/2026" }?.isDirectory == true)
}
