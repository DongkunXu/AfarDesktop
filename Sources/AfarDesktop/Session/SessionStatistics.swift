import AfarKit
import Foundation
import Observation

/// A session's statistics: read once a second while connected, the last minute kept for graphs.
@MainActor
@Observable
final class SessionStatistics {
    static let capacity = 60

    private(set) var history: [StatisticsSample] = []
    /// The codec of the latest graphics updates; kept while the desktop is still.
    private(set) var codec: VideoCodec?
    private(set) var bytesReceived: UInt64 = 0
    private(set) var connectedSince: Date?
    var desktopSize: PixelSize?

    @ObservationIgnored private weak var session: (any RemoteSession)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previous: RemoteStatistics?

    var latest: StatisticsSample? { history.last }

    func start(_ session: any RemoteSession) {
        stop()
        self.session = session
        history = []
        codec = nil
        bytesReceived = 0
        connectedSince = Date()
        previous = session.statistics()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session = nil
        previous = nil
    }

    private func sample() {
        guard let current = session?.statistics() else { return }
        if let previous {
            history.append(StatisticsSample(from: previous, to: current))
            if history.count > Self.capacity { history.removeFirst(history.count - Self.capacity) }
        }
        previous = current
        codec = current.codec ?? codec
        bytesReceived = current.bytesReceived
    }
}
