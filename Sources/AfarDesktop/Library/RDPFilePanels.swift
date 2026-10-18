import AfarKit
import AppKit
import UniformTypeIdentifiers

/// Open and save panels for `.rdp` files.
@MainActor
enum RDPFilePanels {
    static let type = UTType(filenameExtension: "rdp") ?? .data

    static func importFiles(into model: AppModel, selecting select: @escaping (UUID) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose .rdp files to add as computers.")
        guard panel.runModal() == .OK else { return }
        var last: UUID?
        for url in panel.urls { last = model.importRDPFile(at: url) ?? last }
        if let last { select(last) }
    }

    static func export(_ connection: Connection) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(connection.displayName).rdp"
        panel.message = String(localized: "The file contains the address and settings, never the password.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RDPFile.data(for: connection).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

extension AppModel {
    /// Adds the computer described by an .rdp file, or finds the saved one it matches.
    /// Shows an alert and returns nil when the file cannot be read.
    @discardableResult
    func importRDPFile(at url: URL) -> UUID? {
        do {
            let data = try Data(contentsOf: url)
            var connection = try RDPFile.connection(from: data, name: url.deletingPathExtension().lastPathComponent)
            if let existing = store.connections.first(where: {
                $0.host.caseInsensitiveCompare(connection.host) == .orderedSame && $0.port == connection.port
                    && $0.username == connection.username
            }) {
                return existing.id
            }
            connection.commandKey = preferences.defaultCommandKey
            connection.display.renderScale = preferences.defaultRenderScale
            store.add(connection)
            return connection.id
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(url.lastPathComponent)” could not be imported")
            alert.informativeText = error is RDPFile.Error
                ? String(localized: "The file does not describe a remote computer.")
                : error.localizedDescription
            alert.runModal()
            return nil
        }
    }
}
