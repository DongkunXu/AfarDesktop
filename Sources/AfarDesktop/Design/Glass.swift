import AppKit
import SwiftUI

// Liquid Glass on macOS 26 and later, materials before that. Every availability check for the
// app's look lives here, so views only say what they want.

extension View {
    /// A glass surface in `shape`: the floating layer of controls above the content.
    @ViewBuilder
    func glassSurface(in shape: some InsettableShape = Capsule(), tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.85)) }
                    shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            }
        }
    }

    /// Glass for text over arbitrary content (the remote desktop): the same material, darkened in
    /// dark mode and lightened in light mode so the text on it reads clearly.
    func legibleGlassSurface(in shape: some InsettableShape = Capsule(), interactive: Bool = false) -> some View {
        modifier(LegibleGlass(shape: shape, interactive: interactive))
    }

    /// The standard button look for secondary actions.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The standard button look for the main action.
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Content scrolling under floating glass fades softly instead of hitting a hard edge.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

private struct LegibleGlass<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        content.glassSurface(in: shape,
                             tint: colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.55),
                             interactive: interactive)
    }
}

extension View {
    /// Keeps a window toolbar for its layout (window button placement, drag area) while drawing
    /// neither its title nor its background.
    @ViewBuilder
    func hiddenToolbarChrome() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

/// The window's base layer: the desktop blurred through the window, under a light wash of the
/// window colour so the content stays readable.
struct WindowBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
            Color(nsColor: .windowBackgroundColor).opacity(0.55)
        }
        .ignoresSafeArea()
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
