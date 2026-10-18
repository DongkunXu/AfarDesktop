import AfarKit
import AppKit
import Observation

/// Keeps the Mac pasteboard and a session's remote clipboard in step while the session window is
/// in front. macOS has no pasteboard notification, so the change count is checked twice a second;
/// writes coming from the remote side are remembered so they are not echoed back.
///
/// Files copied on the Mac are offered as they are and read when the remote side pastes. Files
/// copied on the remote side have to be downloaded before Finder can paste them: small sets are
/// fetched right away, larger ones after the user agrees (copying a big folder within the remote
/// computer should not start a download).
@MainActor
@Observable
final class SessionClipboard {
    /// What the transfer banner shows.
    enum Transfer: Equatable {
        case offered(count: Int, bytes: UInt64)
        case downloading(fraction: Double)
        case ready(count: Int)
        case failed
    }

    private(set) var transfer: Transfer?

    @ObservationIgnored private weak var session: RDPSession?
    @ObservationIgnored private let downloads: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = -1
    @ObservationIgnored private var download: URL?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// Remote file sets up to this size download without asking.
    static let automaticDownloadLimit: UInt64 = 100 * 1024 * 1024

    init(session: RDPSession, downloads: URL) {
        self.session = session
        self.downloads = downloads
    }

    /// Starts watching (window became key, session connected); offers the current pasteboard.
    func activate() {
        guard timer == nil else { return }
        offerIfChanged()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerIfChanged() }
        }
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
    }

    /// The session is over: stop, and drop the downloaded files nobody can paste any more.
    func end() {
        deactivate()
        dismissTask?.cancel()
        transfer = nil
        removeDownload()
    }

    // MARK: Mac → remote

    private func offerIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !files.isEmpty {
            session?.offerFiles(files)
        } else {
            session?.offerClipboard(Self.content(of: pasteboard))
        }
    }

    /// The pasteboard's main item: an image when the copying app put one first, otherwise its
    /// plain text (rich text included).
    private static func content(of pasteboard: NSPasteboard) -> ClipboardContent? {
        let imageFirst = pasteboard.types?.first.map { [.png, .tiff].contains($0) } ?? false
        if imageFirst || pasteboard.string(forType: .string) == nil,
           let image = NSImage(pasteboard: pasteboard),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return .image(cgImage)
        }
        return pasteboard.string(forType: .string).map { .text($0) }
    }

    // MARK: Remote → Mac

    /// Puts text or an image copied on the remote computer on the Mac pasteboard.
    func receive(_ content: ClipboardContent) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch content {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let image):
            pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        }
        lastChangeCount = pasteboard.changeCount
    }

    func remoteFilesOffered(count: Int, bytes: UInt64) {
        dismissTask?.cancel()
        if bytes <= Self.automaticDownloadLimit {
            startDownload()
        } else {
            transfer = .offered(count: count, bytes: bytes)
        }
    }

    func startDownload() {
        removeDownload()
        let directory = downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        download = directory
        transfer = .downloading(fraction: 0)
        if session?.fetchRemoteFiles(into: directory) != true { finish(success: false) }
    }

    func progress(done: UInt64, total: UInt64) {
        guard case .downloading = transfer else { return }
        transfer = .downloading(fraction: total > 0 ? Double(done) / Double(total) : 0)
    }

    func finish(success: Bool) {
        guard success, let download,
              let items = try? FileManager.default.contentsOfDirectory(at: download, includingPropertiesForKeys: nil),
              !items.isEmpty else {
            if case .downloading = transfer { show(.failed) }
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(items as [NSURL])
        lastChangeCount = pasteboard.changeCount
        show(.ready(count: items.count))
    }

    func dismiss() {
        if case .downloading = transfer { session?.cancelRemoteFiles() }
        dismissTask?.cancel()
        transfer = nil
    }

    /// Shows a final state briefly, then hides the banner.
    private func show(_ state: Transfer) {
        transfer = state
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.transfer = nil
        }
    }

    private func removeDownload() {
        if let download { try? FileManager.default.removeItem(at: download) }
        download = nil
    }
}
