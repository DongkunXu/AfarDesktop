import AfarKit
import SwiftUI

/// The statistics over the desktop, in either form (panel with graphs, or one line of figures).
/// It can be dragged anywhere over the desktop and remembers its place relative to the edges;
/// its button, or a double-click, switches the form.
struct FloatingStatistics: View {
    let statistics: SessionStatistics
    let renderScale: Int?
    @Bindable var preferences: Preferences

    @State private var size = CGSize.zero
    @State private var dragOrigin: CGPoint?
    @State private var dragStart: CGPoint?
    private let margin: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let free = CGSize(width: max(0, geometry.size.width - 2 * margin - size.width),
                              height: max(0, geometry.size.height - 2 * margin - size.height))
            let placed = CGPoint(x: margin + free.width * preferences.statisticsPlacement.x,
                                 y: margin + free.height * preferences.statisticsPlacement.y)
            content
                .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
                .offset(x: (dragOrigin ?? placed).x, y: (dragOrigin ?? placed).y)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let start = dragStart ?? placed
                        dragStart = start
                        dragOrigin = CGPoint(x: min(max(margin, start.x + value.translation.width), margin + free.width),
                                             y: min(max(margin, start.y + value.translation.height), margin + free.height))
                    }
                    .onEnded { _ in
                        if let origin = dragOrigin {
                            preferences.statisticsPlacement = CGPoint(
                                x: free.width > 0 ? (origin.x - margin) / free.width : 1,
                                y: free.height > 0 ? (origin.y - margin) / free.height : 0)
                        }
                        dragOrigin = nil
                        dragStart = nil
                    })
        }
    }

    private var content: some View {
        Group {
            if preferences.compactStatistics {
                StatisticsBar(statistics: statistics, toggle: toggleForm)
            } else {
                StatisticsPanel(statistics: statistics, renderScale: renderScale, toggle: toggleForm)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: toggleForm)
    }

    private func toggleForm() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { preferences.compactStatistics.toggle() }
    }
}

/// Switches between the panel and the single line. Always shown, inside the panel's edge, on a
/// solid disc (white in dark mode, black in light mode) so it stands out from the glass.
private struct FormButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let compact: Bool
    let action: () -> Void

    var body: some View {
        let disc: Color = colorScheme == .dark ? .white : .black
        Button(action: action) {
            Image(systemName: compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .frame(width: 20, height: 20)
                .background(disc, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(compact ? Text("Show graphs") : Text("Show as one line"))
    }
}

/// The full panel: codec and size, three figures with their last minute as graphs, and details.
struct StatisticsPanel: View {
    let statistics: SessionStatistics
    /// nil for fixed-size desktops.
    let renderScale: Int?
    let toggle: () -> Void
    @Environment(\.appAccent) private var accent

    var body: some View {
        let latest = statistics.latest
        let history = statistics.history
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 10) {
                MetricRow(title: Text("Frame rate"),
                          value: latest.map { (String(format: "%.0f", $0.framesPerSecond), "fps") },
                          series: history.map(\.framesPerSecond), floor: 30, tint: accent)
                MetricRow(title: Text("Download"),
                          value: latest.map { StatisticsFormat.bitRate($0.receivedBitsPerSecond) },
                          series: history.map { $0.receivedBitsPerSecond / 1_000_000 }, floor: 1, tint: accent)
                MetricRow(title: Text("Round trip"),
                          value: latest?.roundTripMilliseconds.map { (String(format: "%.0f", $0), "ms") },
                          series: history.compactMap(\.roundTripMilliseconds), floor: 40, tint: accent)
            }

            Divider().opacity(0.6)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    detail(Text("Upload"), latest.map { StatisticsFormat.bitRate($0.sentBitsPerSecond) }.map { "\($0.0) \($0.1)" })
                    detail(Text("Jitter"), latest?.jitterMilliseconds.map { String(format: "±%.0f ms", $0) })
                }
                GridRow {
                    detail(Text("Packet loss"), latest.flatMap(StatisticsFormat.loss))
                    detail(Text("Decode"), latest?.decodeMilliseconds.map { String(format: "%.1f ms", $0) })
                }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 292)
        .legibleGlassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatisticsFormat.codecName(statistics.codec).font(.callout.weight(.semibold))
                if statistics.codec?.isHardwareDecoded == true { HardwareBadge() }
                Spacer(minLength: 8)
                FormButton(compact: false, action: toggle)
            }
            HStack(spacing: 6) {
                if let size = statistics.desktopSize {
                    if let renderScale {
                        Text(verbatim: "\(size.width) × \(size.height) · \(renderScale)%")
                    } else {
                        Text(verbatim: "\(size.width) × \(size.height)")
                    }
                }
                Spacer(minLength: 8)
                // How long the session has run, and what it has received.
                if let since = statistics.connectedSince {
                    Text(since, style: .timer)
                    Text(verbatim: "·")
                }
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(clamping: statistics.bytesReceived),
                                                         countStyle: .file))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func detail(_ title: Text, _ value: String?) -> some View {
        Group {
            title.foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Text(verbatim: value ?? "–")
                .monospacedDigit()
                .frame(minWidth: 62, alignment: .leading)
        }
    }
}

/// The compact form: one line of figures in a glass capsule.
private struct StatisticsBar: View {
    let statistics: SessionStatistics
    let toggle: () -> Void

    var body: some View {
        let latest = statistics.latest
        HStack(spacing: 12) {
            figure(latest.map { String(format: "%.0f", $0.framesPerSecond) }, "fps", width: 22)
            separator
            figure(latest.map { StatisticsFormat.bitRate($0.receivedBitsPerSecond).0 },
                   latest.map { StatisticsFormat.bitRate($0.receivedBitsPerSecond).1 } ?? "Mb/s", width: 30, arrow: "arrow.down")
            separator
            figure(latest?.roundTripMilliseconds.map { String(format: "%.0f", $0) }, "ms", width: 26)
            separator
            HStack(spacing: 4) {
                Text("Packet loss").foregroundStyle(.secondary)
                Text(verbatim: latest.flatMap(StatisticsFormat.worstLoss).map(StatisticsFormat.percent) ?? "–")
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .leading)
            }
            separator
            HStack(spacing: 6) {
                StatisticsFormat.codecName(statistics.codec).fontWeight(.medium)
                if statistics.codec?.isHardwareDecoded == true { HardwareBadge() }
            }
            FormButton(compact: true, action: toggle)
                .padding(.trailing, -6)
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 16)
        .frame(height: 34)
        .legibleGlassSurface(in: Capsule())
    }

    private var separator: some View {
        Divider().frame(height: 14).opacity(0.6)
    }

    private func figure(_ value: String?, _ unit: String, width: CGFloat, arrow: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let arrow {
                Image(systemName: arrow).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            Text(verbatim: value ?? "–")
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(minWidth: width, alignment: .trailing)
            Text(verbatim: unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Marks a codec the Mac decodes in hardware.
private struct HardwareBadge: View {
    @Environment(\.appAccent) private var accent

    var body: some View {
        Text("Hardware")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(accent.opacity(0.22), in: Capsule())
    }
}

/// How figures and codecs are written in both forms.
private enum StatisticsFormat {
    static func codecName(_ codec: VideoCodec?) -> Text {
        switch codec {
        case .h264FullColor: Text(verbatim: "H.264 4:4:4")
        case .h264: Text(verbatim: "H.264")
        case .progressive: Text(verbatim: "RemoteFX Progressive")
        case .remoteFX: Text(verbatim: "RemoteFX")
        case .clearCodec: Text(verbatim: "ClearCodec")
        case .planar: Text(verbatim: "Planar")
        case .alpha: Text(verbatim: "Alpha")
        case .uncompressed: Text("Uncompressed")
        case .other: Text("Other codec")
        case nil: Text("Waiting for the image")
        }
    }

    static func bitRate(_ bitsPerSecond: Double) -> (String, String) {
        if bitsPerSecond >= 1_000_000 {
            let megabits = bitsPerSecond / 1_000_000
            return (String(format: megabits >= 10 ? "%.0f" : "%.1f", megabits), "Mb/s")
        }
        return (String(format: "%.0f", bitsPerSecond / 1000), "kb/s")
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    /// TCP resends whatever is lost, so loss shows only indirectly: data arriving behind a gap
    /// (lost on the way here) and packets this Mac had to send again (lost on the way there).
    static func loss(_ sample: StatisticsSample) -> String? {
        guard let down = sample.outOfOrderFraction, let up = sample.retransmittedFraction else { return nil }
        return "↓\(percent(down)) ↑\(percent(up))"
    }

    static func worstLoss(_ sample: StatisticsSample) -> Double? {
        guard let down = sample.outOfOrderFraction, let up = sample.retransmittedFraction else { return nil }
        return max(down, up)
    }
}

/// One headline figure with its last minute as a small graph.
private struct MetricRow: View {
    let title: Text
    /// The number and its unit; nil while unknown.
    let value: (String, String)?
    let series: [Double]
    /// The graph's top is at least this, so small wobbles stay small.
    let floor: Double
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                title.font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: value?.0 ?? "–")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    if let unit = value?.1 {
                        Text(verbatim: unit).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Sparkline(values: series, floor: floor, capacity: SessionStatistics.capacity, tint: tint)
                .frame(width: 128, height: 32)
        }
    }
}

/// The newest value at the right edge, older ones scrolling off to the left.
private struct Sparkline: View {
    let values: [Double]
    let floor: Double
    let capacity: Int
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(values.max() ?? 0, floor)
            let step = size.width / CGFloat(capacity - 1)
            let inset: CGFloat = 1
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width - step * CGFloat(values.count - 1 - index),
                        y: inset + (size.height - 2 * inset) * (1 - CGFloat(min(value, top) / top)))
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.35), tint.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
