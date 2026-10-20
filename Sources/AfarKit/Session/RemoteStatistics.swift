import AfarEngine
import Foundation

/// A session's counters at one moment, as `RemoteSession.statistics()` reads them.
public struct RemoteStatistics: Sendable {
    /// The TCP connection as the system sees it.
    public struct Connection: Sendable {
        public var roundTrip: Double // milliseconds, smoothed
        public var roundTripVariance: Double
        public var packetsSent: UInt64
        public var packetsRetransmitted: UInt64
        public var bytesReceived: UInt64
        public var outOfOrderBytes: UInt64

        public init(roundTrip: Double, roundTripVariance: Double, packetsSent: UInt64,
                    packetsRetransmitted: UInt64, bytesReceived: UInt64, outOfOrderBytes: UInt64) {
            self.roundTrip = roundTrip
            self.roundTripVariance = roundTripVariance
            self.packetsSent = packetsSent
            self.packetsRetransmitted = packetsRetransmitted
            self.bytesReceived = bytesReceived
            self.outOfOrderBytes = outOfOrderBytes
        }
    }

    /// Seconds on a monotonic clock.
    public var time: TimeInterval
    public var bytesReceived: UInt64
    public var bytesSent: UInt64
    public var frames: UInt64
    public var decodeNanoseconds: UInt64
    /// The codec most graphics updates used since the previous reading; nil when there were none.
    public var codec: VideoCodec?
    /// nil when the system has no figures for the connection (not yet connected).
    public var connection: Connection?

    public init(time: TimeInterval, bytesReceived: UInt64, bytesSent: UInt64, frames: UInt64,
                decodeNanoseconds: UInt64, codec: VideoCodec?, connection: Connection?) {
        self.time = time
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.frames = frames
        self.decodeNanoseconds = decodeNanoseconds
        self.codec = codec
        self.connection = connection
    }

    init(_ s: AfarStatistics, time: TimeInterval) {
        self.init(time: time, bytesReceived: s.bytesReceived, bytesSent: s.bytesSent, frames: s.frames,
                  decodeNanoseconds: s.decodeNanoseconds, codec: VideoCodec(s.codec),
                  connection: s.hasConnectionInfo ? Connection(
                      roundTrip: Double(s.roundTripMs), roundTripVariance: Double(s.roundTripVarianceMs),
                      packetsSent: s.packetsSent, packetsRetransmitted: s.packetsRetransmitted,
                      bytesReceived: s.wireBytesReceived, outOfOrderBytes: s.outOfOrderBytes) : nil)
    }
}

/// How the server encodes the desktop image.
public enum VideoCodec: Sendable, Equatable {
    case uncompressed, planar, clearCodec, remoteFX, progressive
    /// H.264 (AVC420).
    case h264
    /// H.264 with full colour resolution (AVC444): sharper text.
    case h264FullColor
    case alpha
    /// VNC encodings.
    case hextile, zrle, tight, tightJPEG
    case other

    init?(_ codec: AfarCodec) {
        switch codec {
        case AfarCodecUncompressed: self = .uncompressed
        case AfarCodecPlanar: self = .planar
        case AfarCodecClearCodec: self = .clearCodec
        case AfarCodecRemoteFX: self = .remoteFX
        case AfarCodecProgressive: self = .progressive
        case AfarCodecAVC420: self = .h264
        case AfarCodecAVC444: self = .h264FullColor
        case AfarCodecAlpha: self = .alpha
        case AfarCodecOther: self = .other
        default: return nil
        }
    }

    /// Decoded by the Mac's media engine (VideoToolbox).
    public var isHardwareDecoded: Bool { self == .h264 || self == .h264FullColor }
}

/// Rates over the interval between two readings.
public struct StatisticsSample: Equatable, Sendable {
    public var framesPerSecond: Double
    public var receivedBitsPerSecond: Double
    public var sentBitsPerSecond: Double
    /// Average decoding time per frame; nil when no frame arrived.
    public var decodeMilliseconds: Double?
    public var roundTripMilliseconds: Double?
    public var jitterMilliseconds: Double?
    /// Share of the packets this Mac sent that had to be sent again.
    public var retransmittedFraction: Double?
    /// Share of the bytes received that arrived behind a gap, the visible trace of packets lost on
    /// the way here (TCP hides the loss itself by resending).
    public var outOfOrderFraction: Double?

    public init(from old: RemoteStatistics, to new: RemoteStatistics) {
        let seconds = max(new.time - old.time, 0.001)
        let frames = Self.delta(old.frames, new.frames)
        framesPerSecond = Double(frames) / seconds
        receivedBitsPerSecond = Double(Self.delta(old.bytesReceived, new.bytesReceived)) * 8 / seconds
        sentBitsPerSecond = Double(Self.delta(old.bytesSent, new.bytesSent)) * 8 / seconds
        decodeMilliseconds = frames > 0
            ? Double(Self.delta(old.decodeNanoseconds, new.decodeNanoseconds)) / Double(frames) / 1_000_000 : nil

        guard let connection = new.connection else { return }
        roundTripMilliseconds = connection.roundTrip
        jitterMilliseconds = connection.roundTripVariance
        let before = old.connection
        let sent = Self.delta(before?.packetsSent ?? 0, connection.packetsSent)
        let resent = Self.delta(before?.packetsRetransmitted ?? 0, connection.packetsRetransmitted)
        retransmittedFraction = sent > 0 ? min(1, Double(resent) / Double(sent)) : 0
        let received = Self.delta(before?.bytesReceived ?? 0, connection.bytesReceived)
        let outOfOrder = Self.delta(before?.outOfOrderBytes ?? 0, connection.outOfOrderBytes)
        outOfOrderFraction = received > 0 ? min(1, Double(outOfOrder) / Double(received)) : 0
    }

    /// Growth of a counter; a counter that went back started again (a new connection).
    private static func delta(_ old: UInt64, _ new: UInt64) -> UInt64 {
        new >= old ? new - old : new
    }
}
