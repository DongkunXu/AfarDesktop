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

/// The colour resolution choices (`DisplayOptions.fullColor`).
struct ColorQualityPicker: View {
    @Binding var fullColor: Bool

    var body: some View {
        Picker("Colour", selection: $fullColor) {
            Self.label(fullColor: true).tag(true)
            Self.label(fullColor: false).tag(false)
        }
    }

    static func label(fullColor: Bool) -> Text {
        fullColor ? Text("Full colour, 4:4:4 (sharpest text)") : Text("Standard, 4:2:0 (less data)")
    }
}
