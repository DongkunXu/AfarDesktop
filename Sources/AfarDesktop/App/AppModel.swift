import AfarKit
import AppKit
import Observation

/// App-wide state: saved connections, preferences, preview images and open sessions.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let store: ConnectionStore
    let preferences: Preferences
    let thumbnails: ThumbnailStore
    let backdrop: Backdrop
    private(set) var openSessions: [UUID: SessionWindowController] = [:]
    /// Opens the main window; set by the main window's view, usable from AppKit after it closed.
    @ObservationIgnored var showLibrary: (() -> Void)?

    init(paths: AppPaths = .standard) {
        store = ConnectionStore(paths: paths)
        preferences = Preferences()
        thumbnails = ThumbnailStore(paths: paths)
        backdrop = Backdrop(paths: paths)
        // Downloaded clipboard files only matter while their session runs.
        try? FileManager.default.removeItem(at: paths.clipboardFiles)
    }

    func isOpen(_ id: UUID) -> Bool { openSessions[id] != nil }

    /// Brings an open session forward, or opens a new window and connects.
    func connect(_ id: UUID) {
        if let controller = openSessions[id] {
            controller.showWindow(nil)
            return
        }
        guard let connection = store.connection(id) else { return }
        let controller = SessionWindowController(connection: connection, model: self)
        controller.onClose = { [weak self] controller in
            self?.openSessions[controller.connection.id] = nil
        }
        openSessions[id] = controller
        controller.open()
    }

    func save(_ connection: Connection) {
        store.update(connection)
        openSessions[connection.id]?.update(connection)
    }

    func delete(_ id: UUID) {
        openSessions[id]?.close()
        store.delete(id)
        thumbnails.forget(id)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(SessionWindowController.frameAutosaveName(for: id))")
    }

    /// Quits and opens the app again (after the language changes). A small shell waits for this
    /// process to end, for at most ten seconds, so a cancelled quit opens nothing.
    func relaunch() {
        let script = "for i in $(seq 50); do kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || exec /usr/bin/open \"$0\"; sleep 0.2; done"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    func newConnection() -> Connection {
        var connection = Connection()
        connection.display.renderScale = preferences.defaultRenderScale
        connection.commandKey = preferences.defaultCommandKey
        return connection
    }
}
