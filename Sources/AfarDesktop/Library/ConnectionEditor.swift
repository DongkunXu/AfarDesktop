import AfarKit
import SwiftUI

/// Adds or edits a saved computer.
struct ConnectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Connection
    @State private var address: String
    @State private var password = ""
    @State private var forgetPassword = false
    @State private var gatewayAddress: String
    @State private var gatewayUser: String
    @State private var resolution: ResolutionChoice
    @State private var customWidth: Int
    @State private var customHeight: Int
    @State private var errorMessage: String?
    private let hasSavedPassword: Bool
    let isNew: Bool
    let onSave: (Connection) -> Void

    init(connection: Connection, isNew: Bool, onSave: @escaping (Connection) -> Void) {
        _draft = State(initialValue: connection)
        _address = State(initialValue: connection.host.isEmpty ? "" : connection.address)
        _gatewayAddress = State(initialValue: connection.gateway.map {
            $0.port == 443 ? $0.host : "\($0.host):\($0.port)"
        } ?? "")
        _gatewayUser = State(initialValue: connection.gateway?.username ?? "")
        _resolution = State(initialValue: ResolutionChoice(connection.display.resolution))
        if case .fixed(let width, let height) = connection.display.resolution {
            _customWidth = State(initialValue: width)
            _customHeight = State(initialValue: height)
        } else {
            _customWidth = State(initialValue: 1920)
            _customHeight = State(initialValue: 1080)
        }
        hasSavedPassword = CredentialStore().hasPassword(for: .init(connection))
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    TextField("Computer", text: $address, prompt: Text("Name or IP address"))
                    TextField("Display name", text: $draft.name,
                              prompt: address.isEmpty ? Text("Optional") : Text(verbatim: address))
                    groupField
                }

                Section("Sign-in") {
                    TextField("User name", text: $draft.username, prompt: Text("Ask when connecting"))
                    SecureField("Password", text: $password,
                                prompt: hasSavedPassword && !forgetPassword ? Text("Saved in Keychain") : Text("Ask when connecting"))
                    if hasSavedPassword && password.isEmpty {
                        Toggle("Forget saved password", isOn: $forgetPassword)
                    }
                }

                Section("Display") {
                    Picker("Resolution", selection: $resolution) {
                        Text("Fit to window").tag(ResolutionChoice.fitWindow)
                        Divider()
                        ForEach(ResolutionChoice.presets, id: \.self) { preset in
                            Text(verbatim: preset.label).tag(preset)
                        }
                        Divider()
                        Text("Custom…").tag(ResolutionChoice.custom)
                    }
                    if resolution == .custom {
                        LabeledContent("Size") {
                            HStack(spacing: 6) {
                                TextField("Width", value: $customWidth, format: .number.grouping(.never))
                                    .labelsHidden()
                                Text(verbatim: "×").foregroundStyle(.secondary)
                                TextField("Height", value: $customHeight, format: .number.grouping(.never))
                                    .labelsHidden()
                            }
                            .frame(maxWidth: 180)
                        }
                    }
                    if resolution == .fitWindow {
                        RenderScalePicker(selection: $draft.display.renderScale)
                    }
                    ColorQualityPicker(fullColor: $draft.display.fullColor)
                    Picker("Interface scale", selection: $draft.display.scale) {
                        Text("Automatic").tag(Int?.none)
                        ForEach([100, 125, 150, 175, 200, 250, 300], id: \.self) { value in
                            Text(verbatim: "\(value)%").tag(Int?.some(value))
                        }
                    }
                    Toggle("Start in full screen", isOn: $draft.display.startFullScreen)
                }

                Section("Keyboard and Sharing") {
                    Picker("Command key (⌘)", selection: $draft.commandKey) {
                        Text("Acts as Ctrl (⌘C, ⌘V)").tag(CommandKeyMapping.control)
                        Text("Windows / Super key").tag(CommandKeyMapping.windowsKey)
                    }
                    Toggle("Share clipboard", isOn: $draft.clipboard)
                    Toggle("Play sound on this Mac", isOn: $draft.audio)
                }

                Section("Advanced") {
                    TextField("Domain", text: $draft.domain, prompt: Text("Optional"))
                    TextField("Gateway", text: $gatewayAddress, prompt: Text("None"))
                    if !gatewayAddress.trimmingCharacters(in: .whitespaces).isEmpty {
                        TextField("Gateway user name", text: $gatewayUser, prompt: Text("Same as the computer"))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(width: 500, height: 600)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: isNew ? "plus" : "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .glassSurface(in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "Add Computer" : "Edit Computer").font(.title3.weight(.semibold))
                Text("Passwords are kept in your Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .glassButtonStyle()
            Button(isNew ? LocalizedStringKey("Add") : LocalizedStringKey("Save")) { save() }
                .keyboardShortcut(.defaultAction)
                .glassProminentButtonStyle()
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var groupField: some View {
        HStack {
            TextField("Group", text: $draft.group, prompt: Text("None"))
            if !model.store.groups.isEmpty {
                Menu {
                    ForEach(model.store.groups, id: \.self) { group in
                        Button(group) { draft.group = group }
                    }
                    Divider()
                    Button("None") { draft.group = "" }
                } label: {
                    Image(systemName: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose a group")
            }
        }
    }

    // MARK: Saving

    private func save() {
        errorMessage = nil
        var connection = draft
        let (host, port) = Connection.splitAddress(address)
        guard !host.isEmpty else { return }
        connection.host = host
        connection.port = port ?? 3389
        connection.name = connection.name.trimmingCharacters(in: .whitespaces)
        connection.group = connection.group.trimmingCharacters(in: .whitespaces)
        connection.username = connection.username.trimmingCharacters(in: .whitespaces)
        connection.domain = connection.domain.trimmingCharacters(in: .whitespaces)

        let gateway = gatewayAddress.trimmingCharacters(in: .whitespaces)
        if gateway.isEmpty {
            connection.gateway = nil
        } else {
            let (gatewayHost, gatewayPort) = Connection.splitAddress(gateway)
            connection.gateway = Gateway(host: gatewayHost, port: gatewayPort ?? 443,
                                         username: gatewayUser.trimmingCharacters(in: .whitespaces))
        }

        switch resolution {
        case .fitWindow:
            connection.display.resolution = .fitWindow
        case .preset(let width, let height):
            connection.display.resolution = .fixed(width: width, height: height)
        case .custom:
            guard (640...8192).contains(customWidth), (480...8192).contains(customHeight) else {
                errorMessage = String(localized: "Custom sizes must be between 640×480 and 8192×8192.")
                return
            }
            connection.display.resolution = .fixed(width: customWidth, height: customHeight)
        }

        do {
            let key = CredentialStore.Key(connection)
            if !password.isEmpty {
                guard !connection.username.isEmpty else {
                    errorMessage = String(localized: "Enter a user name to save a password.")
                    return
                }
                try model.store.credentials.setPassword(password, for: key, label: connection.keychainLabel)
            } else if forgetPassword {
                try model.store.credentials.removePassword(for: key)
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        onSave(connection)
        dismiss()
    }
}

private enum ResolutionChoice: Hashable {
    case fitWindow
    case preset(Int, Int)
    case custom

    static let presets: [ResolutionChoice] = [
        .preset(1280, 720), .preset(1600, 900), .preset(1920, 1080), .preset(2560, 1440), .preset(3840, 2160),
    ]

    init(_ resolution: DisplayOptions.Resolution) {
        switch resolution {
        case .fitWindow:
            self = .fitWindow
        case .fixed(let width, let height):
            self = Self.presets.contains(.preset(width, height)) ? .preset(width, height) : .custom
        }
    }

    var label: String {
        if case .preset(let width, let height) = self { return "\(width) × \(height)" }
        return ""
    }
}
