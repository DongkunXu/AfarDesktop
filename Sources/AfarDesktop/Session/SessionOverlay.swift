import AfarKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SessionStatus {
    enum Phase: Equatable {
        case connecting(String)
        case connected
        case failed(SessionFailure)
    }

    var phase: Phase = .connecting("")
    /// The session's clipboard, for the file transfer banner.
    var clipboard: SessionClipboard?
    let statistics = SessionStatistics()
    /// The connection's render scale; nil for fixed-size desktops.
    var renderScale: Int?
    /// The connection asks for full colour detail.
    var fullColor = true
    var remoteProtocol = RemoteProtocol.rdp
}

/// What went wrong, in words for the user.
struct SessionFailure: Equatable {
    var title: String
    var message: String
    var detail: String?
    /// The failure was about credentials, so asking for the password again may help.
    var offerPassword: Bool

    init(_ error: SessionError?) {
        detail = error.flatMap { error in error.detail.map { "\($0) (0x\(String(error.code, radix: 16, uppercase: true)))" } }
        offerPassword = false
        switch error?.reason {
        case .authentication:
            title = String(localized: "Sign-in failed")
            message = String(localized: "The remote computer did not accept the user name or password.")
            offerPassword = true
        case .certificate:
            title = String(localized: "Connection not trusted")
            message = String(localized: "The remote computer's certificate was not accepted.")
        case .hostNotFound:
            title = String(localized: "Computer not found")
            message = String(localized: "Check the computer name, or connect with its IP address.")
        case .unreachable:
            title = String(localized: "Could not connect")
            message = String(localized: "The remote computer did not answer. Check that it is on, that remote desktop is enabled and that the network allows the connection.")
        case .replaced:
            title = String(localized: "Session taken over")
            message = String(localized: "Someone connected to this computer from another device.")
        case .timeout:
            title = String(localized: "Session timed out")
            message = String(localized: "The remote computer ended the session after a period of inactivity.")
        case .serverDenied:
            title = String(localized: "Access denied")
            message = String(localized: "The remote computer does not allow this account to connect.")
        case .networkLost:
            title = String(localized: "Connection lost")
            message = String(localized: "The network connection to the remote computer was interrupted.")
        case .unsupported:
            title = String(localized: "Not supported")
            message = String(localized: "The remote computer asks for something Afar Desktop cannot do yet.")
        case .other, nil:
            title = String(localized: "Connection ended")
            message = String(localized: "The session ended unexpectedly.")
        }
    }
}

/// Shown over the desktop while connecting and after a failure; while connected, only the file
/// transfer banner and the statistics panel appear.
struct SessionOverlay: View {
    @Environment(AppModel.self) private var model
    struct Actions {
        var cancel: () -> Void
        var reconnect: () -> Void
        var reconnectWithPassword: () -> Void
        var close: () -> Void
    }

    let status: SessionStatus
    let actions: Actions

    var body: some View {
        ZStack {
            switch status.phase {
            case .connected:
                Color.clear.allowsHitTesting(false)
            case .connecting(let name):
                panel {
                    ProgressView().controlSize(.regular)
                    Text("Connecting to \(name)…")
                        .font(.headline)
                    Button("Cancel", action: actions.cancel)
                        .keyboardShortcut(.cancelAction)
                        .glassButtonStyle()
                }
            case .failed(let failure):
                panel {
                    Image(systemName: failure.offerPassword ? "lock" : "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 52, height: 52)
                        .legibleGlassSurface(in: Circle())
                    VStack(spacing: 6) {
                        Text(failure.title).font(.title3.weight(.semibold))
                        Text(failure.message)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 340)
                    }
                    if let detail = failure.detail {
                        Text(detail).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                    HStack(spacing: 10) {
                        Button("Close", action: actions.close)
                            .keyboardShortcut(.cancelAction)
                            .glassButtonStyle()
                        if failure.offerPassword {
                            Button("Enter Password…", action: actions.reconnectWithPassword)
                                .keyboardShortcut(.defaultAction)
                                .glassProminentButtonStyle()
                        } else {
                            Button("Reconnect", action: actions.reconnect)
                                .keyboardShortcut(.defaultAction)
                                .glassProminentButtonStyle()
                        }
                    }
                    .controlSize(.large)
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if status.phase == .connected, let clipboard = status.clipboard, let transfer = clipboard.transfer {
                TransferBanner(transfer: transfer, clipboard: clipboard)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if status.phase == .connected, model.preferences.showsStatistics {
                FloatingStatistics(statistics: status.statistics, renderScale: status.renderScale,
                                   preferences: model.preferences)
                    .transition(.opacity)
            }
        }
        .environment(\.appAccent, model.backdrop.accent ?? .accentColor)
        .animation(.easeOut(duration: 0.2), value: status.phase)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: status.clipboard?.transfer)
        .animation(.easeOut(duration: 0.2), value: model.preferences.showsStatistics)
    }

    private func panel(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 16, content: content)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(minWidth: 300)
                .legibleGlassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .transition(.opacity)
    }
}

/// A small glass banner for files copied on the remote computer.
private struct TransferBanner: View {
    let transfer: SessionClipboard.Transfer
    let clipboard: SessionClipboard

    var body: some View {
        HStack(spacing: 12) {
            switch transfer {
            case .offered(let count, let bytes):
                Image(systemName: "doc.on.clipboard")
                Text(count == 1 ? "1 item copied on the remote computer (\(size(bytes)))"
                                : "\(count) items copied on the remote computer (\(size(bytes)))")
                Button("Download") { clipboard.startDownload() }
                    .glassProminentButtonStyle()
                dismissButton
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 140)
                Text("Downloading for this Mac… \(Int(fraction * 100))%")
                    .monospacedDigit()
                dismissButton
            case .ready(let count):
                Image(systemName: "checkmark.circle")
                Text(count == 1 ? "Ready to paste on this Mac" : "\(count) items ready to paste on this Mac")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                Text("The files could not be downloaded.")
                dismissButton
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .legibleGlassSurface(in: Capsule())
    }

    private var dismissButton: some View {
        Button { clipboard.dismiss() } label: {
            Image(systemName: "xmark").font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .help("Dismiss")
    }

    private func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
