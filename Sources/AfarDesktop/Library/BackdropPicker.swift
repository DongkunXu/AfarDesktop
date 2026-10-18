import AppKit
import SwiftUI

/// The main window's background: the built-in pictures, the user's own picture, a solid colour and
/// a button to add a picture, in rows that wrap to the width, with the opacity below. Shown in
/// Settings and from the navigation panel.
struct BackdropPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var backdrop = model.backdrop
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tile<EmptyView>.size.width), spacing: 8)], spacing: 8) {
                ForEach(Array(backdrop.builtIns.indices), id: \.self) { index in
                    let number = index + 1
                    Tile(selected: backdrop.choice == .builtIn(number)) {
                        backdrop.select(.builtIn(number))
                    } content: {
                        picture(backdrop.thumbnail(builtIn: number))
                    }
                }
                if backdrop.hasOwnPicture {
                    Tile(selected: backdrop.choice == .ownPicture, remove: backdrop.removeOwnPicture) {
                        backdrop.select(.ownPicture)
                    } content: {
                        picture(backdrop.thumbnail(builtIn: nil))
                    }
                    .help(Text("Your picture"))
                }
                colorTile
                Tile(selected: false, action: choosePicture) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.06))
                }
                .help(Text("Choose a picture…"))
            }
            LabeledContent {
                Slider(value: $backdrop.opacity, in: 0.1...0.9)
            } label: {
                Text("Opacity")
            }
        }
    }

    private var colorTile: some View {
        let backdrop = model.backdrop
        let current: Backdrop.RGB = if case .color(let rgb) = backdrop.choice { rgb } else { Backdrop.defaultColor }
        let selected = if case .color = backdrop.choice { true } else { false }
        return Tile(selected: selected) {
            backdrop.select(.color(current))
            ColorPanelBridge.shared.open(with: current.nsColor) { color in
                if let rgb = Backdrop.RGB(color) { backdrop.select(.color(rgb)) }
            }
        } content: {
            ZStack {
                current.color
                Image(systemName: "paintpalette")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .help(Text("Solid colour"))
    }

    private func picture(_ image: NSImage?) -> some View {
        Color.primary.opacity(0.06)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose a picture for the main window.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.backdrop.importPicture(from: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct Tile<Content: View>: View {
    @Environment(\.appAccent) private var accent
    let selected: Bool
    var remove: (() -> Void)?
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    static var size: CGSize { CGSize(width: 76, height: 48) }
    private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        Button(action: action) {
            content
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(selected ? accent : Color.primary.opacity(hovering ? 0.25 : 0.1),
                                       lineWidth: selected ? 2.5 : 0.5)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let remove, hovering {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassSurface(in: Circle(), interactive: true)
                .offset(x: 5, y: -5)
                .help(Text("Remove"))
            }
        }
        .onHover { hovering = $0 }
    }
}

/// Sends the shared colour panel's choices to whoever opened it last.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(with color: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        self.onChange = onChange
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}
