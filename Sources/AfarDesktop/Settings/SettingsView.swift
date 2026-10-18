import AfarKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    /// The language the app runs in now, to tell whether a restart is needed.
    @State private var launchLanguage = AppModel.shared.preferences.language

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Picker("Language", selection: $preferences.language) {
                    Text("System default").tag(String?.none)
                    Divider()
                    ForEach(Preferences.languages, id: \.code) { language in
                        Text(verbatim: language.name).tag(String?.some(language.code))
                    }
                }
                if preferences.language != launchLanguage {
                    LabeledContent {
                        Button("Restart Now") { model.relaunch() }
                    } label: {
                        Text("Afar Desktop uses the new language after a restart.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                BackdropPicker()
            } header: {
                Text("Background")
            } footer: {
                Text("The highlight colour is taken from the background.")
                    .foregroundStyle(.secondary)
            }
            Section("Sessions") {
                Picker("Open sessions in", selection: $preferences.openInTabs) {
                    Text("Separate windows").tag(false)
                    Text("Tabs").tag(true)
                }
            }
            Section {
                RenderScalePicker(selection: $preferences.defaultRenderScale)
                Picker("Command key (⌘)", selection: $preferences.defaultCommandKey) {
                    Text("Acts as Ctrl (⌘C, ⌘V)").tag(CommandKeyMapping.control)
                    Text("Windows / Super key").tag(CommandKeyMapping.windowsKey)
                }
            } header: {
                Text("New connections")
            } footer: {
                Text("Each connection can change these in its own settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 540)
        .environment(\.appAccent, model.backdrop.accent ?? .accentColor)
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(verbatim: "Afar Desktop").font(.title2.weight(.semibold))
                Text("Version \(Bundle.main.shortVersion)")
                    .foregroundStyle(.secondary)
            }
            Text("A remote desktop client for the Mac, built on FreeRDP.")
                .multilineTextAlignment(.center)
            Text("Released under the Apache License 2.0.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
