@testable import AfarKit
import Testing

@Test func normalEndHasNoError() {
    #expect(RDPError(code: 0, message: nil) == nil)
}

@Test func unknownCodeIsOther() {
    #expect(RDPError(code: 0xFFFF_FFFF, message: "x")?.reason == .other)
}
