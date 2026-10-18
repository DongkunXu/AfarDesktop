import Foundation

/// Files and folders flattened for the remote clipboard: each entry has the name the remote side
/// sees (relative to the copied items, "/"-separated), folders before their contents.
/// Symbolic links are left out (following them could offer files from anywhere on the disk), and
/// so are hidden files inside folders, such as .DS_Store.
struct ClipboardFileList {
    struct Entry: Equatable {
        var url: URL
        var name: String
        var isDirectory: Bool
        var size: UInt64
    }

    private(set) var entries: [Entry] = []

    init(_ urls: [URL]) {
        for url in urls { add(url, name: url.lastPathComponent) }
    }

    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    private mutating func add(_ url: URL, name: String) {
        guard let values = try? url.resourceValues(forKeys: Self.keys), values.isSymbolicLink != true else { return }
        let isDirectory = values.isDirectory == true
        entries.append(Entry(url: url, name: name, isDirectory: isDirectory,
                             size: isDirectory ? 0 : UInt64(values.fileSize ?? 0)))
        guard isDirectory,
              let children = try? FileManager.default.contentsOfDirectory(
                  at: url, includingPropertiesForKeys: Array(Self.keys), options: [.skipsHiddenFiles])
        else { return }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            add(child, name: "\(name)/\(child.lastPathComponent)")
        }
    }
}
