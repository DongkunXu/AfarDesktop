import AfarKit
import SwiftUI

/// The session window's controls, at the trailing end of its title bar so the window keeps the
/// standard (smallest) title bar height.
struct SessionTitleControls: View {
    struct Actions {
        var setRenderScale: @MainActor @Sendable (Int) -> Void
        var setFullColor: @MainActor @Sendable (Bool) -> Void
        var fullScreen: () -> Void
        var disconnect: () -> Void
    }

    @Environment(AppModel.self) private var model
    let status: SessionStatus
    let actions: Actions

    var body: some View {
        HStack(spacing: 2) {
            if let renderScale = status.renderScale {
                renderScaleMenu(renderScale)
            }
            colorMenu
            button("chart.xyaxis.line", Text("Statistics"), active: model.preferences.showsStatistics) {
                model.preferences.showsStatistics.toggle()
            }
            button("arrow.up.left.and.arrow.down.right", Text("Full Screen"), action: actions.fullScreen)
            button("power", Text("Disconnect"), action: actions.disconnect)
        }
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .tint(model.backdrop.accent ?? .accentColor)
    }

    private func renderScaleMenu(_ renderScale: Int) -> some View {
        Menu {
            Picker(selection: Binding(get: { renderScale }, set: actions.setRenderScale)) {
                ForEach(DisplayOptions.renderScales, id: \.self) { percent in
                    RenderScalePicker.label(for: percent).tag(percent)
                }
            } label: {
                Text("Render scale")
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                Text(verbatim: "\(renderScale)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            // Highlighted while the desktop is drawn below full resolution.
            .foregroundStyle(renderScale < 100 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .frame(width: 58, height: 22)
        .help(Text("Render scale"))
    }

    private var colorMenu: some View {
        Menu {
            Picker(selection: Binding(get: { status.fullColor }, set: actions.setFullColor)) {
                ColorQualityPicker.label(fullColor: true, status.remoteProtocol).tag(true)
                ColorQualityPicker.label(fullColor: false, status.remoteProtocol).tag(false)
            } label: {
                Text("Colour")
            }
            .pickerStyle(.inline)
            Text("Changing it reconnects the session.")
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 11, weight: .medium))
                ColorQualityPicker.shortLabel(fullColor: status.fullColor, status.remoteProtocol)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            // Highlighted while colour detail is reduced.
            .foregroundStyle(status.fullColor ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: 22)
        .help(Text("Colour"))
    }

    private func button(_ symbol: String, _ label: Text, active: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(label)
        .accessibilityLabel(label)
    }
}
