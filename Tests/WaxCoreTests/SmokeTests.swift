import Testing
@testable import WaxCore

@Test func packageBuilds() async throws {
    let _ = Wax.self
}

@Test func errorTypesExist() {
    let error: WaxError = .invalidHeader(reason: "test")
    #expect(error.localizedDescription.isEmpty == false)
}

@Test func constantsAreCorrect() {
    #expect(Constants.magic == "WAX1".data(using: .utf8)!)
    #expect(Constants.headerSize == 4096)
    #expect(Constants.footerMagic == "WAX1FOOT".data(using: .utf8)!)
}
