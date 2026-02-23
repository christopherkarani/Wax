import Foundation
import Testing
@testable import WaxCore

@Test func openWithRepairTruncatesTrailingBytes() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("hello".utf8))
        try await wax.commit()
        try await wax.close()
    }

    let originalSize: UInt64
    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }
        originalSize = try file.size()
        try file.writeAll(Data(repeating: 0xFF, count: 32), at: originalSize)
        try file.fsync()
    }

    do {
        let file = try FDFile.openReadOnly(at: url)
        defer { try? file.close() }
        #expect(try file.size() == originalSize + 32)
    }

    guard let slice = try FooterScanner.findLastValidFooter(in: url) else {
        #expect(Bool(false))
        return
    }
    let expectedEnd = slice.footerOffset + Constants.footerSize

    do {
        let wax = try await Wax.open(at: url, repair: true)
        try await wax.close()
    }

    do {
        let file = try FDFile.openReadOnly(at: url)
        defer { try? file.close() }
        #expect(try file.size() == expectedEnd)
    }
}

@Test func deepVerifyDetectsPayloadCorruption() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("payload".utf8))
        try await wax.commit()
        try await wax.close()
    }

    guard let slice = try FooterScanner.findLastValidFooter(in: url) else {
        #expect(Bool(false))
        return
    }
    let toc = try WaxTOC.decode(from: slice.tocBytes)
    guard let frame = toc.frames.first else {
        #expect(Bool(false))
        return
    }

    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }
        var firstByte = try file.readExactly(length: 1, at: frame.payloadOffset)
        firstByte[0] ^= 0xFF
        try file.writeAll(firstByte, at: frame.payloadOffset)
        try file.fsync()
    }

    do {
        let wax = try await Wax.open(at: url)
        do {
            try await wax.verify(deep: true)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .checksumMismatch = error else {
                #expect(Bool(false))
                return
            }
        }
        try await wax.close()
    }
}
