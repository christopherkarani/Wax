import Foundation
import Testing
@testable import WaxCore

#if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
@Test func waxFileSetsCompleteProtection() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    try await wax.close()

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let protection = attributes[.protectionKey] as? FileProtectionType
    #expect(protection == .complete)
}
#endif

@Test func waxFileIsReadableAfterCreate() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    try await wax.close()

    #expect(FileManager.default.isReadableFile(atPath: url.path))
}
