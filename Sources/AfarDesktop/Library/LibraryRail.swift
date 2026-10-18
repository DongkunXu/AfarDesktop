import AfarKit
import SwiftUI

/// The floating navigation panel, full window height: the window buttons sit in its top edge,
/// large icon buttons below them expand to show their names, and the app's name and version
/// close it at the bottom. Its trailing edge can be dragged to resize it, or to expand and
/// collapse it.
struct LibraryRail: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: LibraryFilter
    @Binding var expanded: Bool
    /// The expanded width, kept within `widthRange`.
    @Binding var width: Double
    @State private var dragStartWidth: Double?
    @State private var showsBackdrop = false

    /// Collapsed, the panel is just wide enough for the three window buttons.
    static let collapsedWidth: CGFloat = 76
    static let widthRange: ClosedRange<Double> = 160...300

    var currentWidth: CGFloat { Self.width(expanded: expanded, width: width) }

    static func width(expanded: Bool, width: Double) -> CGFloat {
        expanded ? CGFloat(min(max(width, widthRange.lowerBound), widthRange.upperBound)) : collapsedWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 30) // the window buttons

            RailButton(title: expanded ? Text("Collapse") : Text("Expand"),
                       systemImage: "sidebar.left", expanded: expanded, selected: false) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
            }

            divider

            item(.all, Text("All Computers"), "square.grid.2x2")
            item(.recent, Text("Recent"), "clock")

            if !model.store.groups.isEmpty {
                divider
                if expanded {
                    Text("Groups")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .transition(.opacity)
                }
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(model.store.groups, id: \.self) { group in
                            item(.group(group), Text(verbatim: group), "folder")
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            RailButton(title: Text("Background"), systemImage: "photo.on.rectangle", expanded: expanded,
                       selected: false) { showsBackdrop.toggle() }
                .popover(isPresented: $showsBackdrop, arrowEdge: .trailing) {
                    BackdropPicker()
                        .padding(16)
                        .frame(width: 400)
                        .environment(model)
                        .environment(\.appAccent, model.backdrop.accent ?? .accentColor)
                }

            SettingsLink {
                RailLabel(title: Text("Settings"), systemImage: "gearshape", expanded: expanded, selected: false)
            }
            .buttonStyle(.plain)
            .help(Text("Settings"))

            divider
            footer
        }
        .padding(8)
        .frame(width: currentWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .trailing) { resizeHandle }
    }

    /// An invisible strip on the trailing edge. Dragging it resizes the expanded panel; dragging
    /// well past either end of the range expands or collapses it.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? Double(currentWidth)
                    dragStartWidth = start
                    let proposed = start + value.translation.width
                    if !expanded {
                        if proposed > Double(Self.collapsedWidth) + 40 {
                            width = min(max(proposed, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded = true }
                        }
                    } else if proposed < Self.widthRange.lowerBound - 50 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded = false }
                    } else {
                        width = min(max(proposed, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                    }
                }
                .onEnded { _ in dragStartWidth = nil })
    }

    private var divider: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 4).opacity(0.6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
                .frame(width: 44)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "Afar Desktop").font(.caption.weight(.semibold))
                    Text(verbatim: Bundle.main.shortVersion).font(.caption2).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
        .padding(.vertical, 4)
        .help(Text(verbatim: "Afar Desktop \(Bundle.main.shortVersion)"))
    }

    private func item(_ target: LibraryFilter, _ title: Text, _ systemImage: String) -> some View {
        RailButton(title: title, systemImage: systemImage, expanded: expanded, selected: filter == target) {
            filter = target
        }
    }
}

private struct RailButton: View {
    let title: Text
    let systemImage: String
    let expanded: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RailLabel(title: title, systemImage: systemImage, expanded: expanded, selected: selected)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct RailLabel: View {
    @Environment(\.appAccent) private var accent
    let title: Text
    let systemImage: String
    let expanded: Bool
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44)
            if expanded {
                title
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(selected ? accent : Color.primary)
        .frame(height: 40)
        // Collapsed, the icon sits in the middle of the panel.
        .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? accent.opacity(0.16) : (hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}
