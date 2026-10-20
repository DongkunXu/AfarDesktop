import AfarKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window: saved computers on a translucent base, with the navigation rail, the search
/// field and the add button floating above them in glass.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("LibraryRailExpanded") private var railExpanded = false
    @AppStorage("LibraryRailWidth") private var railWidth = 220.0
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var selection: UUID?
    @State private var editing: EditRequest?
    @State private var deleting: Connection?
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    private let margin: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowBackground()
            backdropImage

            content
                .padding(.leading, LibraryRail.width(expanded: railExpanded, width: railWidth) + margin)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: railExpanded)

            // Full height, with the window buttons sitting inside its top edge.
            LibraryRail(filter: $filter, expanded: $railExpanded, width: $railWidth)
                .padding(margin)

            addButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(24)
        }
        .ignoresSafeArea()
        .toolbar { ToolbarItem(placement: .automatic) { Color.clear.frame(width: 1, height: 1) } }
        .hiddenToolbarChrome()
        .environment(\.appAccent, accent)
        .tint(accent)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(accent, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: importDropped)
        .sheet(item: $editing) { request in
            ConnectionEditor(connection: request.connection, isNew: request.isNew) { saved in
                model.save(saved)
                selection = saved.id
            }
            .environment(model)
        }
        .confirmationDialog(deleteTitle, isPresented: deleteDialogShown, presenting: deleting) { connection in
            Button("Delete", role: .destructive) { model.delete(connection.id) }
        } message: { _ in
            Text("Its saved password and preview are removed too.")
        }
        .onAppear { model.showLibrary = { [openWindow] in openWindow(id: "library") } }
        .onReceive(NotificationCenter.default.publisher(for: .newConnectionRequested)) { _ in startNew() }
        .onReceive(NotificationCenter.default.publisher(for: .findRequested)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .importRequested)) { _ in
            RDPFilePanels.importFiles(into: model) { selection = $0 }
        }
        .onChange(of: model.store.groups) { _, groups in
            if case .group(let name) = filter, !groups.contains(name) { filter = .all }
        }
    }

    private var accent: Color { model.backdrop.accent ?? .accentColor }

    /// The chosen picture or colour, sharp and partly transparent over the window's blurred base.
    @ViewBuilder
    private var backdropImage: some View {
        Group {
            if case .color(let rgb) = model.backdrop.choice {
                rgb.color
            } else if let image = model.backdrop.image {
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            }
        }
        .opacity(model.backdrop.opacity)
        .allowsHitTesting(false)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.store.connections.isEmpty {
            EmptyLibrary(add: startNew)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if visible.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        grid
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 44)
                .padding(.bottom, 110) // room for the add button
            }
            .softScrollEdges()
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                model.connect(selection)
                return .handled
            }
            .onDeleteCommand { deleting = selection.flatMap { model.store.connection($0) } }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(filter.title)
                    .font(.largeTitle.weight(.semibold))
                Text(countText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            SearchField(text: $search, focused: $searchFocused)
                .frame(maxWidth: 260)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 22)], spacing: 26) {
            ForEach(visible) { connection in
                ConnectionCard(connection: connection, isSelected: selection == connection.id,
                               isOpen: model.isOpen(connection.id)) { menu(for: connection) }
                    .onTapGesture(count: 2) { model.connect(connection.id) }
                    .simultaneousGesture(TapGesture().onEnded { selection = connection.id })
                    .contextMenu { menu(for: connection) }
            }
        }
    }

    private var addButton: some View {
        Button(action: startNew) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), tint: accent.opacity(0.8), interactive: true)
        .help("Add a remote computer")
        .accessibilityLabel("New Connection")
    }

    @ViewBuilder
    private func menu(for connection: Connection) -> some View {
        Button("Connect") { model.connect(connection.id) }
        Button("Edit…") { editing = EditRequest(connection: connection, isNew: false) }
        Button("Duplicate") {
            if let copy = model.store.duplicate(connection.id) { selection = copy.id }
        }
        if connection.remoteProtocol == .rdp {
            Button("Export as .rdp File…") { RDPFilePanels.export(connection) }
        }
        Divider()
        Button("Delete…", role: .destructive) { deleting = connection }
    }

    // MARK: Filtering

    private var visible: [Connection] {
        var list = model.store.connections
        switch filter {
        case .all:
            list.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .recent:
            list = list.filter { $0.lastConnected != nil }
                .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
        case .group(let name):
            list = list.filter { $0.group == name }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter {
            [$0.displayName, $0.host, $0.username, $0.group].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var countText: String {
        let count = visible.count
        return count == 1 ? String(localized: "1 computer") : String(localized: "\(count) computers")
    }

    // MARK: Actions

    private func startNew() {
        var connection = model.newConnection()
        if case .group(let name) = filter { connection.group = name }
        editing = EditRequest(connection: connection, isNew: true)
    }

    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        let rdp = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !rdp.isEmpty else { return false }
        for provider in rdp {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "rdp" else { return }
                Task { @MainActor in
                    if let id = model.importRDPFile(at: url) { selection = id }
                }
            }
        }
        return true
    }

    private var deleteTitle: String {
        deleting.map { String(localized: "Delete “\($0.displayName)”?") } ?? ""
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

private struct EditRequest: Identifiable {
    var connection: Connection
    var isNew: Bool
    var id: UUID { connection.id }
}

enum LibraryFilter: Hashable {
    case all, recent
    case group(String)

    var title: String {
        switch self {
        case .all: String(localized: "All Computers")
        case .recent: String(localized: "Recent")
        case .group(let name): name
        }
    }
}

/// A search field in a glass capsule.
private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassSurface(in: Capsule())
    }
}

/// Shown until the first computer is added.
private struct EmptyLibrary: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "link")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 92, height: 92)
                .glassSurface(in: Circle())
            VStack(spacing: 6) {
                Text("No Computers Yet")
                    .font(.title2.weight(.semibold))
                Text("Add a remote computer to connect to it with one click.")
                    .foregroundStyle(.secondary)
            }
            Button("Add Computer…", action: add)
                .controlSize(.large)
                .glassButtonStyle()
        }
        .padding(40)
    }
}
