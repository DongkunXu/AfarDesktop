import AfarKit
import AppKit
import SwiftUI

/// One window per open connection: runs the session, shows its desktop, asks for certificates
/// and passwords, shares the clipboard, and offers to reconnect when the connection drops.
@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    private(set) var connection: Connection
    private let model: AppModel
    private let sessionView = SessionView()
    private let status = SessionStatus()
    private let titleControls = NSTitlebarAccessoryViewController()
    private var session: RDPSession?
    private var clipboard: SessionClipboard?
    private var layoutTimer: Timer?
    private var thumbnailTimer: Timer?
    private var keyUpMonitor: Any?
    /// The next attempt asks for the password instead of using the saved one.
    private var askForPassword = false
    private var closing = false

    var onClose: ((SessionWindowController) -> Void)?

    init(connection: Connection, model: AppModel) {
        self.connection = connection
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.tabbingMode = model.preferences.openInTabs ? .preferred : .disallowed
        window.tabbingIdentifier = "AfarDesktop.Session"
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.backgroundColor = .black

        titleControls.layoutAttribute = .trailing
        titleControls.view = NSHostingView(rootView: SessionTitleControls(status: status, actions: titleActions)
            .environment(model))
        window.addTitlebarAccessoryViewController(titleControls)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = container

        sessionView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sessionView)
        let overlay = NSHostingView(rootView: SessionOverlay(status: status, actions: overlayActions)
            .environment(model))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        // The desktop sits below the title bar; in full screen the title bar slides over it.
        NSLayoutConstraint.activate([
            sessionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sessionView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sessionView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sessionView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        sessionView.onLayoutChange = { [weak self] in self?.scheduleLayout() }
        apply(connection)

        window.setFrameAutosaveName(Self.frameAutosaveName(for: connection.id))
        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.setContentSize(defaultContentSize())
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func frameAutosaveName(for id: UUID) -> String { "Session-\(id.uuidString)" }

    // MARK: Opening

    func open() {
        showWindow(nil)
        window?.makeFirstResponder(sessionView)
        installKeyUpMonitor()
        if connection.display.startFullScreen, window?.styleMask.contains(.fullScreen) == false {
            window?.toggleFullScreen(nil)
            // Connect once the window has its full-screen size.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.connect() }
        } else {
            connect()
        }
    }

    /// The saved connection changed while the window is open; display and keyboard settings
    /// apply at once, the rest on the next connection.
    func update(_ connection: Connection) {
        self.connection = connection
        apply(connection)
        scheduleLayout()
    }

    private func apply(_ connection: Connection) {
        window?.title = connection.displayName
        window?.subtitle = connection.address
        sessionView.commandKey = connection.commandKey
        if case .fixed = connection.display.resolution {
            sessionView.preservesAspectRatio = true
            status.renderScale = nil
        } else {
            sessionView.preservesAspectRatio = false
            status.renderScale = connection.display.renderScale
        }
        status.fullColor = connection.display.fullColor
        // The render scale menu comes and goes with the resolution mode. The controls take the
        // title bar's full height so they sit on its centre line.
        let titleBarHeight = window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 28
        titleControls.view.frame.size = NSSize(width: titleControls.view.fittingSize.width, height: titleBarHeight)
    }

    private func defaultContentSize() -> NSSize {
        if case .fixed(let width, let height) = connection.display.resolution {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            return NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        }
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: (visible.width * 0.8).rounded(), height: (visible.height * 0.8).rounded())
    }

    // MARK: Connecting

    private func connect() {
        teardownSession()
        let session = RDPSession()
        session.delegate = self
        sessionView.session = session
        self.session = session
        clipboard = connection.clipboard
            ? SessionClipboard(session: session, downloads: model.store.paths.clipboardFiles) : nil
        status.clipboard = clipboard

        let credentials = model.store.credentials
        let password = askForPassword ? nil : credentials.password(for: CredentialStore.Key(connection))
        askForPassword = false
        let gateway = connection.gateway.map { gateway in
            RDPSession.Parameters.GatewayParameters(
                host: gateway.host, port: gateway.port,
                username: gateway.usesComputerCredentials ? nil : gateway.username,
                password: CredentialStore.Key(gatewayOf: connection).flatMap(credentials.password(for:)))
        }
        let layout = currentLayout().cappedForConnect

        status.phase = .connecting(connection.displayName)
        do {
            try session.connect(.init(
                host: connection.host, port: connection.port,
                username: connection.username.isEmpty ? nil : connection.username,
                domain: connection.domain.isEmpty ? nil : connection.domain,
                password: password,
                width: layout.width, height: layout.height,
                desktopScale: layout.desktopScale, deviceScale: layout.deviceScale,
                fullColor: connection.display.fullColor, audio: connection.audio, clipboard: connection.clipboard, gateway: gateway,
                configDirectory: model.store.paths.engine))
        } catch {
            status.phase = .failed(SessionFailure(error as? RDPError))
        }
    }

    private func teardownSession() {
        status.statistics.stop()
        clipboard?.end()
        clipboard = nil
        status.clipboard = nil
        guard let session else { return }
        session.delegate = nil
        sessionView.session = nil
        self.session = nil
        // Joining the engine thread can take a moment; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { session.close() }
    }

    private var isConnected: Bool { session?.state == .connected }

    // MARK: Layout

    private func currentLayout() -> DesktopLayout {
        let size = sessionView.bounds.width > 0 ? sessionView.bounds.size
            : (window?.contentLayoutRect.size ?? defaultContentSize())
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return DesktopLayout(display: connection.display, viewSize: size, backingScale: backing)
    }

    /// Waits for the window to settle before asking the server for a new size.
    private func scheduleLayout() {
        layoutTimer?.invalidate()
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendLayout() }
        }
    }

    private func sendLayout() {
        guard let session, isConnected else { return }
        let layout = currentLayout()
        session.requestLayout(width: layout.width, height: layout.height,
                              desktopScale: layout.desktopScale, deviceScale: layout.deviceScale)
    }

    // MARK: Keyboard

    /// AppKit drops key-up events while ⌘ is held; without them the remote side would see the
    /// key stuck. Catch them before AppKit discards them.
    private func installKeyUpMonitor() {
        guard keyUpMonitor == nil else { return }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), event.window === self.window,
                  self.window?.firstResponder === self.sessionView else { return event }
            self.sessionView.keyUp(with: event)
            return nil
        }
    }

    // MARK: Window

    func windowDidResignKey(_ notification: Notification) {
        sessionView.releaseInput()
        clipboard?.deactivate()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(sessionView)
        if isConnected { clipboard?.activate() }
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        saveThumbnail()
        layoutTimer?.invalidate()
        thumbnailTimer?.invalidate()
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        keyUpMonitor = nil
        teardownSession()
        onClose?(self)
    }

    private func saveThumbnail() {
        guard let image = sessionView.snapshot(maxWidth: 640) else { return }
        model.thumbnails.save(image, for: connection.id)
    }

    /// Keeps the connection's card preview current: once the desktop has settled after
    /// connecting, then every few minutes while connected.
    private func startThumbnailUpdates() {
        thumbnailTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.isConnected else { return }
            self.saveThumbnail()
        }
        thumbnailTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isConnected else { return }
                self.saveThumbnail()
            }
        }
    }

    // MARK: Actions

    private var titleActions: SessionTitleControls.Actions {
        SessionTitleControls.Actions(
            setRenderScale: { [weak self] in self?.setRenderScale($0) },
            setFullColor: { [weak self] in self?.setFullColor($0) },
            fullScreen: { [weak self] in self?.window?.toggleFullScreen(nil) },
            disconnect: { [weak self] in self?.window?.performClose(nil) })
    }

    /// Saved with the connection, so the next session starts the same way.
    private func setRenderScale(_ percent: Int) {
        guard connection.display.renderScale != percent else { return }
        connection.display.renderScale = percent
        model.save(connection)
    }

    /// Colour resolution is agreed when the session starts, so changing it reconnects.
    private func setFullColor(_ fullColor: Bool) {
        guard connection.display.fullColor != fullColor else { return }
        connection.display.fullColor = fullColor
        model.save(connection)
        if session != nil { connect() }
    }

    private var overlayActions: SessionOverlay.Actions {
        SessionOverlay.Actions(
            cancel: { [weak self] in self?.window?.performClose(nil) },
            reconnect: { [weak self] in self?.connect() },
            reconnectWithPassword: { [weak self] in
                self?.askForPassword = true
                self?.connect()
            },
            close: { [weak self] in self?.window?.performClose(nil) })
    }

    @objc func sendCtrlAltDelete(_ sender: Any?) {
        guard let session, isConnected else { return }
        let keys: [UInt16] = [0x3B, 0x3A, 0x75] // control, option (alt), forward delete
        keys.forEach { session.sendKey($0, down: true) }
        keys.reversed().forEach { session.sendKey($0, down: false) }
    }

    @objc func disconnectSession(_ sender: Any?) {
        window?.performClose(nil)
    }
}

// MARK: - Session events

extension SessionWindowController: RDPSessionDelegate {
    func session(_ session: RDPSession, stateChanged state: RDPSession.State) {
        guard session === self.session else { return }
        switch state {
        case .idle, .connecting:
            break
        case .connected:
            status.phase = .connected
            model.store.markConnected(connection.id)
            window?.makeFirstResponder(sessionView)
            if window?.isKeyWindow == true { clipboard?.activate() }
            scheduleLayout()
            startThumbnailUpdates()
            status.statistics.start(session)
        case .disconnected(let error):
            clipboard?.deactivate()
            status.statistics.stop()
            thumbnailTimer?.invalidate()
            saveThumbnail()
            if closing { return }
            if let error {
                status.phase = .failed(SessionFailure(error))
            } else {
                // Signed out or closed from the other side: nothing left to show.
                window?.close()
            }
        }
    }

    func session(_ session: RDPSession, surfaceChanged surface: IOSurface, size: PixelSize) {
        sessionView.show(surface: surface, size: size)
        status.statistics.desktopSize = size
    }

    func session(_ session: RDPSession, frameUpdated surface: IOSurface) {
        sessionView.show(frame: surface)
    }

    func sessionDisplayControlReady(_ session: RDPSession) {
        sendLayout()
    }

    func session(_ session: RDPSession, verify certificate: CertificateInfo,
                 decide: @escaping @Sendable (CertificateDecision) -> Void) {
        guard let window else { return decide(.reject) }
        CertificatePrompt.present(certificate, connectionName: connection.displayName, on: window, decide: decide)
    }

    func session(_ session: RDPSession, credentialsFor request: CredentialRequest,
                 provide: @escaping @Sendable (Credentials?) -> Void) {
        guard let window else { return provide(nil) }
        let username: String
        if !request.username.isEmpty {
            username = request.username
        } else if request.gateway, let gateway = connection.gateway, !gateway.usesComputerCredentials {
            username = gateway.username
        } else {
            username = connection.username
        }
        CredentialPrompt.present(on: window, connectionName: connection.displayName, gateway: request.gateway,
                                 username: username) { [weak self] result in
            guard let self, let result else { return provide(nil) }
            self.remember(result, gateway: request.gateway)
            provide(result.credentials)
        }
    }

    /// Stores what the user typed: the user name in the connection, the password in the Keychain
    /// when asked to.
    private func remember(_ result: CredentialPrompt.Result, gateway: Bool) {
        let typed = result.credentials.username
        if gateway, var gatewaySettings = connection.gateway, !gatewaySettings.usesComputerCredentials {
            if typed != gatewaySettings.username {
                gatewaySettings.username = typed
                connection.gateway = gatewaySettings
                model.save(connection)
            }
        } else if !gateway, typed != connection.username {
            connection.username = typed
            model.save(connection)
        }
        guard result.savePassword else { return }
        let key = gateway ? CredentialStore.Key(gatewayOf: connection) : CredentialStore.Key(connection)
        let label = gateway ? "\(connection.displayName) gateway (Afar Desktop)" : connection.keychainLabel
        if let key { try? model.store.credentials.setPassword(result.credentials.password, for: key, label: label) }
    }

    func session(_ session: RDPSession, cursorCreated cursor: CursorImage) {
        sessionView.addCursor(cursor)
    }

    func session(_ session: RDPSession, cursorReleased id: UInt64) {
        sessionView.removeCursor(id)
    }

    func session(_ session: RDPSession, cursorChanged cursor: RemoteCursor) {
        sessionView.setCursor(cursor)
    }

    func session(_ session: RDPSession, clipboardReceived content: ClipboardContent) {
        clipboard?.receive(content)
    }

    func session(_ session: RDPSession, remoteFilesOffered count: Int, bytes: UInt64) {
        clipboard?.remoteFilesOffered(count: count, bytes: bytes)
    }

    func session(_ session: RDPSession, remoteFilesProgress done: UInt64, of total: UInt64) {
        clipboard?.progress(done: done, total: total)
    }

    func session(_ session: RDPSession, remoteFilesFinished success: Bool) {
        clipboard?.finish(success: success)
    }
}
