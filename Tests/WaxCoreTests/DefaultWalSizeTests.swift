import Foundation
import Testing
@testable import WaxCore

@Test func createUsesLongTermWalSizeByDefault() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let walStats = await wax.walStats()
    try await wax.close()

    #expect(walStats.walSize == Constants.longTermWalSize)
}

@Test func emptyStoreLogicalSizeIsNotLegacyLargeWal() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    try await wax.close()

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let logicalSize = try #require(attributes[.size] as? NSNumber).uint64Value
    #expect(logicalSize < Constants.legacyLargeWalSize)
}

@Test func sessionWalSizeUnchanged() {
    #expect(Constants.sessionWalSize == 4 * 1024 * 1024)
}
