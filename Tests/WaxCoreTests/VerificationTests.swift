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

@Test func openRepairFsyncsAfterTruncatingTrailingBytes() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxCore/Wax.swift"),
        encoding: .utf8
    )
    let repairBlock = try #require(source.range(of: "if repair, fileSize > requiredEnd {"))
    let remainder = source[repairBlock.lowerBound...]
    let blockEnd = try #require(remainder.range(of: "let dataEnd = max(fileSize, requiredEnd)"))
    let body = remainder[..<blockEnd.lowerBound]

    let truncate = try #require(body.range(of: "try file.truncate(to: requiredEnd)"))
    let fsync = try #require(body.range(of: "try file.fsync()"))
    #expect(truncate.lowerBound < fsync.lowerBound)
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

@Test func verifyUsesSameNewestFooterSelectionAsOpen() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let firstFooter: FooterSlice
    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("first".utf8))
        try await wax.commit()
        firstFooter = try #require(try FooterScanner.findLastValidFooter(in: url))

        _ = try await wax.put(Data("second".utf8))
        try await wax.commit()
        try await wax.close()
    }

    let latestFooter = try #require(try FooterScanner.findLastValidFooter(in: url))
    let latestTOC = try WaxTOC.decode(from: latestFooter.tocBytes)
    let secondFrame = try #require(latestTOC.frames.first { $0.id == 1 })

    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }

        var payloadByte = try file.readExactly(length: 1, at: secondFrame.payloadOffset)
        payloadByte[0] ^= 0xFF
        try file.writeAll(payloadByte, at: secondFrame.payloadOffset)

        let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        let selected = try #require(WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB))
        var stalePointerHeader = selected.page
        stalePointerHeader.footerOffset = firstFooter.footerOffset
        stalePointerHeader.tocChecksum = firstFooter.footer.tocHash

        let selectedOffset = UInt64(selected.pageIndex) * Constants.headerPageSize
        try file.writeAll(try stalePointerHeader.encodeWithChecksum(), at: selectedOffset)
        try file.fsync()
    }

    let wax = try await Wax.open(at: url, repair: false)
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
