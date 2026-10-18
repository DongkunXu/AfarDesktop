import AfarKit
import SwiftUI

/// A saved computer: the last image of its desktop, its name and address. On hover, a button
/// in the corner opens the same menu as a right-click.
struct ConnectionCard<Menu: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appAccent) private var accent
    let connection: Connection
    let isSelected: Bool
    let isOpen: Bool
    @ViewBuilder let menu: Menu
    @State private var hovering = false

    private let corner = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(corner)
                .overlay {
                    corner.strokeBorder(isSelected ? accent : Color.primary.opacity(0.08),
                                        lineWidth: isSelected ? 2.5 : 0.5)
                }
                .overlay(alignment: .topLeading) { if isOpen { connectedBadge } }
                .overlay { if hovering { connectButton } }
                .overlay(alignment: .topTrailing) { if hovering { moreButton } }
                .shadow(color: .black.opacity(hovering ? 0.22 : 0.10), radius: hovering ? 16 : 6, y: hovering ? 8 : 3)
                .scaleEffect(hovering ? 1.015 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(connection.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .help(connection.address)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        connection.username.isEmpty ? connection.address : "\(connection.username) · \(connection.address)"
    }

    @ViewBuilder
    private var preview: some View {
        if let image = model.thumbnails.image(for: connection.id) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            // No image yet: a glass plate with the initials, readable over any background.
            ZStack {
                Color.clear
                Text(initials)
                    .font(.system(size: 40, weight: .ultraLight, design: .rounded))
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 0 : 1) // the connect button takes its place
            }
            .glassSurface(in: Rectangle())
        }
    }

    private var connectedBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("Connected").font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .glassSurface(in: Capsule())
        .padding(10)
    }

    private var connectButton: some View {
        Button { model.connect(connection.id) } label: {
            Image(systemName: isOpen ? "arrow.up.forward" : "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), interactive: true)
        .help(isOpen ? "Show Session" : "Connect")
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private var moreButton: some View {
        SwiftUI.Menu {
            menu
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassSurface(in: Circle(), interactive: true)
        .padding(10)
        .help("More")
        .transition(.opacity)
    }

    private var initials: String {
        let words = connection.displayName.split(whereSeparator: { " -._".contains($0) })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
