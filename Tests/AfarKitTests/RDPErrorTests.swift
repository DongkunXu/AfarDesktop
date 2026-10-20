@testable import AfarKit
import Testing

@Test func normalEndHasNoError() {
    #expect(SessionError(rdpCode: 0, message: nil) == nil)
}

@Test func unknownCodeIsOther() {
    #expect(SessionError(rdpCode: 0xFFFF_FFFF, message: "x")?.reason == .other)
}
