import AfarKit
import SwiftUI

/// The render scale choices (`DisplayOptions.renderScale`), the same wherever they appear.
struct RenderScalePicker: View {
    @Binding var selection: Int

    var body: some View {
        Picker("Render scale", selection: $selection) {
            ForEach(DisplayOptions.renderScales, id: \.self) { percent in
                Self.label(for: percent).tag(percent)
            }
        }
    }

    static func label(for percent: Int) -> Text {
        switch percent {
        case 100: Text("100% (sharpest)")
        case DisplayOptions.renderScales.last: Text("\(percent)% (least data)")
        default: Text(verbatim: "\(percent)%")
        }
    }
}

/// The colour detail choices (`DisplayOptions.fullColor`): H.264 4:4:4 or 4:2:0 for RDP,
/// lossless encodings or JPEG for VNC.
struct ColorQualityPicker: View {
    @Binding var fullColor: Bool
    var remoteProtocol: RemoteProtocol = .rdp

    var body: some View {
        Picker("Colour", selection: $fullColor) {
            Self.label(fullColor: true, remoteProtocol).tag(true)
            Self.label(fullColor: false, remoteProtocol).tag(false)
        }
    }

    static func label(fullColor: Bool, _ remoteProtocol: RemoteProtocol) -> Text {
        switch (remoteProtocol, fullColor) {
        case (.rdp, true): Text("Full colour, 4:4:4 (sharpest text)")
        case (.rdp, false): Text("Standard, 4:2:0 (less data)")
        case (.vnc, true): Text("Lossless (sharpest)")
        case (.vnc, false): Text("JPEG (less data)")
        }
    }

    /// The short form in the session's title bar.
    static func shortLabel(fullColor: Bool, _ remoteProtocol: RemoteProtocol) -> Text {
        switch (remoteProtocol, fullColor) {
        case (.rdp, true): Text(verbatim: "4:4:4")
        case (.rdp, false): Text(verbatim: "4:2:0")
        case (.vnc, true): Text("Lossless")
        case (.vnc, false): Text(verbatim: "JPEG")
        }
    }
}
