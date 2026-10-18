import AfarKit
import AppKit
import SwiftUI

/// Asks whether to trust a remote computer's certificate.
enum CertificatePrompt {
    @MainActor
    static func present(_ certificate: CertificateInfo, connectionName: String, on window: NSWindow,
                        decide: @escaping @Sendable (CertificateDecision) -> Void) {
        let alert = NSAlert()
        if certificate.changed {
            alert.alertStyle = .critical
            alert.messageText = String(localized: "The certificate of \(connectionName) has changed")
            alert.informativeText = String(localized: "This can happen after the remote computer was reinstalled or its remote desktop settings changed. It can also mean someone is intercepting the connection. Continue only if you expected the change.")
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Trust New Certificate"))
        } else {
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Trust \(connectionName)?")
            alert.informativeText = String(localized: "Afar Desktop cannot verify the identity of this computer. Its certificate is self-signed or issued for another name, which is common for remote desktops. Compare the fingerprint with the one shown on the remote computer if you are unsure.")
            alert.addButton(withTitle: String(localized: "Trust and Connect"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        }
        alert.accessoryView = details(certificate)
        alert.beginSheetModal(for: window) { response in
            let accepted = certificate.changed ? response == .alertSecondButtonReturn : response == .alertFirstButtonReturn
            decide(accepted ? .acceptAlways : .reject)
        }
    }

    @MainActor
    private static func details(_ certificate: CertificateInfo) -> NSView {
        var rows: [(String, String)] = [
            (String(localized: "Name"), certificate.commonName),
            (String(localized: "Issuer"), certificate.issuer),
            (String(localized: "Fingerprint"), certificate.fingerprint),
        ]
        if let previous = certificate.previousFingerprint, certificate.changed {
            rows.append((String(localized: "Previous"), previous))
        }
        let view = NSHostingView(rootView: Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: 380, alignment: .leading)
        .padding(.vertical, 4))
        view.frame.size = view.fittingSize
        return view
    }
}

/// Asks for a user name and password.
enum CredentialPrompt {
    struct Result {
        var credentials: Credentials
        var savePassword: Bool
    }

    @MainActor
    static func present(on window: NSWindow, connectionName: String, gateway: Bool, username: String,
                        completion: @escaping (Result?) -> Void) {
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let finish: (Result?) -> Void = { [weak window, weak sheet] result in
            if let sheet { window?.endSheet(sheet) }
            completion(result)
        }
        sheet.contentView = NSHostingView(rootView: CredentialForm(
            title: gateway ? String(localized: "Sign in to the gateway for \(connectionName)")
                           : String(localized: "Sign in to \(connectionName)"),
            username: username, finish: finish))
        sheet.setContentSize(sheet.contentView!.fittingSize)
        window.beginSheet(sheet)
    }
}

private struct CredentialForm: View {
    let title: String
    @State var username: String
    @State private var password = ""
    @State private var savePassword = true
    @FocusState private var focus: Field?
    let finish: (CredentialPrompt.Result?) -> Void

    enum Field { case username, password }

    init(title: String, username: String, finish: @escaping (CredentialPrompt.Result?) -> Void) {
        self.title = title
        _username = State(initialValue: username)
        self.finish = finish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "key")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glassSurface(in: Circle())
                Text(title).font(.title3.weight(.semibold))
            }
            Form {
                TextField("User name", text: $username)
                    .focused($focus, equals: .username)
                SecureField("Password", text: $password)
                    .focused($focus, equals: .password)
                Toggle("Remember password in Keychain", isOn: $savePassword)
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                    .glassButtonStyle()
                Button("Connect") {
                    finish(.init(credentials: Credentials(username: username, password: password),
                                 savePassword: savePassword))
                }
                .keyboardShortcut(.defaultAction)
                .glassProminentButtonStyle()
                .disabled(username.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { focus = username.isEmpty ? .username : .password }
    }
}
