import Testing
@testable import WaxCore

// Keep a single non-theater smoke check: wire-format constants used across codecs/layout.
@Test func constantsAreCorrect() {
    #expect(Constants.magic == "WAX1".data(using: .utf8)!)
    #expect(Constants.headerSize == 4096)
    #expect(Constants.headerPageSize == 4096)
    #expect(Constants.headerRegionSize == 8192)
    #expect(Constants.footerSize == 64)
    #expect(Constants.walRecordHeaderSize == 48)
    #expect(Constants.footerMagic == "WAX1FOOT".data(using: .utf8)!)
    #expect(Constants.specMajor == 1)
    #expect(Constants.specMinor == 0)
    #expect(Constants.specVersion == 0x0100)
}
