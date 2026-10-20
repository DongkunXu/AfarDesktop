@testable import AfarKit
import Testing

private func reading(at time: Double, received: UInt64, frames: UInt64, decode: UInt64,
                     sent packets: UInt64, resent: UInt64, wire: UInt64, outOfOrder: UInt64) -> RemoteStatistics {
    RemoteStatistics(time: time, bytesReceived: received, bytesSent: received / 100, frames: frames,
                  decodeNanoseconds: decode, codec: .h264FullColor,
                  connection: .init(roundTrip: 40, roundTripVariance: 5, packetsSent: packets,
                                    packetsRetransmitted: resent, bytesReceived: wire, outOfOrderBytes: outOfOrder))
}

@Test func sampleTurnsCountersIntoRates() {
    let old = reading(at: 10, received: 1_000_000, frames: 100, decode: 0, sent: 1000, resent: 0, wire: 1_000_000, outOfOrder: 0)
    let new = reading(at: 12, received: 3_500_000, frames: 160, decode: 240_000_000, sent: 1200, resent: 2,
                      wire: 3_500_000, outOfOrder: 25_000)
    let sample = StatisticsSample(from: old, to: new)
    #expect(sample.framesPerSecond == 30)
    #expect(sample.receivedBitsPerSecond == 10_000_000)
    #expect(sample.decodeMilliseconds == 4)
    #expect(sample.roundTripMilliseconds == 40)
    #expect(sample.retransmittedFraction == 0.01)
    #expect(sample.outOfOrderFraction == 0.01)
}

@Test func sampleSurvivesReconnection() {
    let old = reading(at: 10, received: 9_000_000, frames: 500, decode: 0, sent: 5000, resent: 9, wire: 9_000_000, outOfOrder: 900)
    let new = reading(at: 11, received: 9_125_000, frames: 510, decode: 0, sent: 100, resent: 0, wire: 125_000, outOfOrder: 0)
    let sample = StatisticsSample(from: old, to: new)
    #expect(sample.receivedBitsPerSecond == 1_000_000)
    #expect(sample.retransmittedFraction == 0)
    #expect(sample.outOfOrderFraction == 0)
}

@Test func stillDesktopHasNoDecodeTime() {
    let old = reading(at: 0, received: 0, frames: 7, decode: 1000, sent: 0, resent: 0, wire: 0, outOfOrder: 0)
    let new = reading(at: 1, received: 0, frames: 7, decode: 1000, sent: 0, resent: 0, wire: 0, outOfOrder: 0)
    #expect(StatisticsSample(from: old, to: new).decodeMilliseconds == nil)
}
