import Testing
@testable import WaxCore

@Test func packageBuilds() async throws {
    let _ = Wax.self
}

@Test func errorTypesExist() throws {
    let error: WaxError = .invalidHeader(reason: "test")
    #expect(error.localizedDescription.isEmpty == false)
}

@Test func constantsAreCorrect() {
    #expect(Constants.magic == "MV2S".data(using: .utf8)!)
    #expect(Constants.headerSize == 4096)
    #expect(Constants.footerMagic == "MV2SFOOT".data(using: .utf8)!)
}
