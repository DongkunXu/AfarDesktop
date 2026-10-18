import AfarKit
import AppKit
import SwiftUI

@main
struct AfarDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Afar Desktop", id: "library") {
            LibraryView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 460)
        }
        // An empty unified toolbar: no title or bar is drawn, and macOS places the window
        // buttons inset, inside the navigation panel's top edge.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1040, height: 680)
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opening an .rdp file (double-click, drag onto the Dock icon) adds it and connects.
    func application(_ application: NSApplication, open urls: [URL]) {
        let model = AppModel.shared
        for url in urls where url.pathExtension.lowercased() == "rdp" {
            if let id = model.importRDPFile(at: url) { model.connect(id) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let open = AppModel.shared.openSessions.count
        guard open > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = open == 1
            ? String(localized: "Disconnect the open session and quit?")
            : String(localized: "Disconnect \(open) open sessions and quit?")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A click on the Dock icon brings back the main window. Its scene is not recreated on its
    /// own once closed, so it is opened explicitly (or brought forward when it is open).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showLibrary?()
        return false
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { showLibrary(then: .newConnectionRequested) }
                .keyboardShortcut("n")
            Button("Import .rdp Files…") { showLibrary(then: .importRequested) }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { showLibrary(then: .findRequested) }
                .keyboardShortcut("f")
        }
        CommandMenu("Session") {
            Toggle("Show Statistics", isOn: Binding(
                get: { AppModel.shared.preferences.showsStatistics },
                set: { AppModel.shared.preferences.showsStatistics = $0 }))
            Divider()
            Button("Send Ctrl+Alt+Del") {
                NSApp.sendAction(#selector(SessionWindowController.sendCtrlAltDelete(_:)), to: nil, from: nil)
            }
            Divider()
            Button("Disconnect") {
                NSApp.sendAction(#selector(SessionWindowController.disconnectSession(_:)), to: nil, from: nil)
            }
        }
        CommandGroup(before: .windowList) {
            Button("Connections") { openWindow(id: "library") }
                .keyboardShortcut("0")
            Divider()
        }
    }

    private func showLibrary(then request: Notification.Name) {
        openWindow(id: "library")
        NotificationCenter.default.post(name: request, object: nil)
    }
}

extension Notification.Name {
    static let newConnectionRequested = Notification.Name("AfarDesktop.NewConnectionRequested")
    static let importRequested = Notification.Name("AfarDesktop.ImportRequested")
    static let findRequested = Notification.Name("AfarDesktop.FindRequested")
}
