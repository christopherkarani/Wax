import Foundation
import Testing
@testable import WaxCore

// A frame import writes payloads straight to the data region and publishes every frame and
// embedding in one commit: nothing goes through the WAL, nothing is visible or durable before
// that commit, and an abandoned or crashed import leaves the store as it was.

private let importDimension = 8

private func importPayload(_ index: Int) -> Data {
    Data("imported frame \(index) ".utf8) + Data(repeating: UInt8(truncatingIfNeeded: index), count: 300)
}

private func importVector(_ index: Int) -> [Float] {
    (0..<importDimension).map { Float((index * importDimension + $0) % 89) * 0.01 + 0.5 }
}

private func importOptions(_ range: Range<Int>) -> [FrameMetaSubset] {
    range.map { index in
        var option = FrameMetaSubset(role: .document, metadata: Metadata(["row": String(index)]))
        option.searchText = "imported frame \(index)"
        return option
    }
}

private func fileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
}

/// Opens a store with one committed frame and its vector, and a small WAL, so an import far
/// larger than the WAL would have had to commit several times through it.
private func seededStore(_ url: URL) async throws -> Wax {
    let wax = try await Wax.create(at: url, walSize: 64 * 1024)
    let seed = try await wax.put(Data("seed".utf8), options: FrameMetaSubset(role: .document))
    try await wax.putEmbedding(frameId: seed, vector: importVector(-1))
    try await wax.setVectorIndexConfiguration(dimension: UInt32(importDimension), similarity: .cosine)
    try await wax.commit()
    return wax
}

/// Imports `range` in batches of 500, with an embedding per frame.
private func importRange(_ range: Range<Int>, into wax: Wax) async throws -> [UInt64] {
    var ids: [UInt64] = []
    for lower in stride(from: range.lowerBound, to: range.upperBound, by: 500) {
        let batch = lower..<min(lower + 500, range.upperBound)
        let frameIds = try await wax.importFrames(batch.map(importPayload), options: importOptions(batch))
        try await wax.importEmbeddings(frameIds: frameIds, vectors: batch.map(importVector))
        ids += frameIds
    }
    return ids
}

@Test func frameImportCommitsOnceWithoutWritingTheWAL() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        let generationBefore = await wax.stats().generation
        let walBefore = await wax.walStats()
        let count = 3_000

        #expect(try await wax.beginFrameImport())
        let ids = try await importRange(0..<count, into: wax)
        #expect(ids == (1...UInt64(count)).map { $0 })
        try await wax.commitFrameImport()

        let stats = await wax.stats()
        #expect(stats.frameCount == UInt64(count + 1))
        #expect(stats.pendingFrames == 0)
        #expect(stats.generation == generationBefore + 1, "one commit for the whole import")
        let walAfter = await wax.walStats()
        #expect(walAfter.writePos == walBefore.writePos, "nothing went through the WAL")
        #expect(walAfter.autoCommitCount == walBefore.autoCommitCount)
        #expect(await wax.hasOpenFrameImport() == false)
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        try await reopened.verify(deep: true)
        #expect(await reopened.stats().frameCount == UInt64(count + 1))
        for index in [0, 1, count / 2, count - 1] {
            let frameId = ids[index]
            #expect(try await reopened.frameContent(frameId: frameId) == importPayload(index))
            let meta = try await reopened.frameMeta(frameId: frameId)
            #expect(meta.metadata?.entries["row"] == String(index))
            #expect(meta.searchText == "imported frame \(index)")
            #expect(meta.role == .document)
        }
        let vectors = try #require(try await reopened.readCommittedVectors())
        #expect(vectors.frameIds.count == count + 1)
        let row = try #require(vectors.frameIds.firstIndex(of: ids[7]))
        let stored = Array(vectors.vectors[(row * importDimension)..<((row + 1) * importDimension)])
        #expect(stored == importVector(7))
        try await reopened.close()
    }
}

@Test func frameImportIsInvisibleUntilItCommits() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        #expect(try await wax.beginFrameImport())
        let ids = try await importRange(0..<20, into: wax)

        let stats = await wax.stats()
        #expect(stats.frameCount == 1)
        #expect(stats.pendingFrames == 0)
        #expect(await wax.frameMetasIncludingPending().count == 1)
        await #expect(throws: (any Error).self) {
            _ = try await wax.frameMetaIncludingPending(frameId: ids[0])
        }
        #expect(try await wax.committedVectorFrameIds() == [0])

        try await wax.commitFrameImport()
        #expect(await wax.frameMetasIncludingPending().count == 21)
        #expect(try await wax.committedVectorFrameIds().count == 21)
        try await wax.close()
    }
}

@Test func abandonedFrameImportLeavesTheStoreAsItWasAndFreesItsSpace() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        let framesBefore = await wax.frameMetas()
        let generationBefore = await wax.stats().generation
        let freeBefore = await wax.freeDataRangesForTesting()

        #expect(try await wax.beginFrameImport())
        _ = try await importRange(0..<1_000, into: wax)
        await wax.abandonFrameImport()

        #expect(await wax.hasOpenFrameImport() == false)
        #expect(await wax.frameMetas() == framesBefore)
        #expect(await wax.stats().generation == generationBefore)
        let freeBytesBefore = freeBefore.reduce(0) { $0 + $1.count }
        let freeBytesAfter = await wax.freeDataRangesForTesting().reduce(0) { $0 + $1.count }
        #expect(freeBytesAfter >= freeBytesBefore + 1_000 * 300, "the import's payloads are free space")

        // The next import writes its payloads into that space.
        let sizeAfterAbandon = try fileSize(url)
        #expect(try await wax.beginFrameImport())
        let ids = try await importRange(0..<1_000, into: wax)
        try await wax.commitFrameImport()
        #expect(ids.first == 1)
        let imported = await wax.frameMetas().dropFirst()
        #expect(imported.count == 1_000)
        #expect(imported.allSatisfy { $0.payloadOffset + $0.payloadLength <= sizeAfterAbandon })
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        try await reopened.verify(deep: true)
        #expect(await reopened.stats().frameCount == 1_001)
        try await reopened.close()
    }
}

@Test func crashDuringFrameImportRecoversThePreviousCommit() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        let framesBefore = await wax.frameMetas()
        #expect(try await wax.beginFrameImport())
        _ = try await importRange(0..<2_000, into: wax)

        // A copy of the file as it is on disk now stands in for a crash of the open handle.
        let crashed = TempFiles.uniqueURL()
        defer { try? FileManager.default.removeItem(at: crashed) }
        try FileManager.default.copyItem(at: url, to: crashed)
        await wax.abandonFrameImport()
        try await wax.close()

        let crashedSize = try fileSize(crashed)
        let recovered = try await Wax.open(at: crashed)
        try await recovered.verify(deep: true)
        #expect(await recovered.frameMetas() == framesBefore)
        #expect(await recovered.stats().pendingFrames == 0)
        #expect(try await recovered.committedVectorFrameIds() == [0])

        // The crashed import's payloads are free space: a commit truncates them away.
        _ = try await recovered.put(importPayload(9), options: FrameMetaSubset(role: .document))
        try await recovered.commit()
        #expect(try fileSize(crashed) < crashedSize)
        #expect(await recovered.stats().frameCount == 2)
        try await recovered.close()
    }
}

@Test func writesWaitForAnOpenFrameImportAndFollowIt() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        #expect(try await wax.beginFrameImport())
        let ids = try await importRange(0..<10, into: wax)

        let put = Task { () async throws -> UInt64 in
            try await wax.put(Data("after import".utf8), options: FrameMetaSubset(role: .document))
        }
        let commit = Task { () async throws -> Void in
            try await wax.commit()
        }
        while await wax.frameImportWaiterCountForTesting() < 2 {
            await Task.yield()
        }
        #expect(await wax.stats().pendingFrames == 0, "the put waits for the import")

        try await wax.commitFrameImport()
        let putId = try await put.value
        try await commit.value
        #expect(putId == (ids.last ?? 0) + 1)
        try await wax.commit()
        #expect(await wax.stats().frameCount == 12)
        try await wax.close()
    }
}

@Test func frameImportRequiresACommittedStore() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        _ = try await wax.put(Data("pending".utf8), options: FrameMetaSubset(role: .document))
        #expect(try await wax.beginFrameImport() == false)
        #expect(await wax.hasOpenFrameImport() == false)
        try await wax.commit()
        #expect(try await wax.beginFrameImport())
        await #expect(throws: (any Error).self) {
            try await wax.importEmbeddings(frameIds: [0], vectors: [[1, 2, 3]])
        }
        await wax.abandonFrameImport()
        try await wax.close()
    }
}

private func noisePayload(_ seed: Int, byteCount: Int = 4_096) -> Data {
    var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1
    var bytes: [UInt8] = []
    bytes.reserveCapacity(byteCount)
    for _ in 0..<byteCount {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        bytes.append(UInt8(truncatingIfNeeded: state))
    }
    return Data(bytes)
}

private func freeBytes(_ wax: Wax) async -> UInt64 {
    await wax.freeDataRangesForTesting().reduce(UInt64(0)) { (total: UInt64, range: Range<UInt64>) -> UInt64 in
        total + UInt64(range.count)
    }
}

@Test func failedPayloadWriteReleasesTheSpaceItAllocated() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        #expect(try await wax.beginFrameImport())
        _ = try await importRange(0..<10, into: wax)
        let freeBefore = await freeBytes(wax)

        await wax.installFileFaultPlanForTesting(FDFileFaultPlan(pwrite: [.eio]))
        await #expect(throws: (any Error).self) {
            _ = try await wax.importFrames((10..<210).map(importPayload), options: importOptions(10..<210))
        }
        await wax.installFileFaultPlanForTesting(nil)

        #expect(await freeBytes(wax) >= freeBefore + 200 * 300, "the failed batch's space is free again")
        #expect(await wax.frameImportPayloadRangesForTesting().count == 1)

        // The import goes on from where it was.
        let ids = try await importRange(10..<20, into: wax)
        #expect(ids == (11...20).map { UInt64($0) })
        try await wax.commitFrameImport()
        try await wax.close()
        let reopened = try await Wax.open(at: url)
        try await reopened.verify(deep: true)
        #expect(await reopened.stats().frameCount == 21)
        try await reopened.close()
    }
}

/// How many `pwrite`s an import commit of `range` into a fresh seeded store makes before its
/// header write, counted on a probe store.
private func pwritesBeforeImportCommitHeader(_ range: Range<Int>) async throws -> Int {
    try await TempFiles.withTempFile { probeURL in
        let probe = try await seededStore(probeURL)
        #expect(try await probe.beginFrameImport())
        _ = try await importRange(range, into: probe)
        await probe.installFileFaultPlanForTesting(FDFileFaultPlan(recordsOperations: true))
        try await probe.commitFrameImport()
        let operations = await probe.recordedFileOperationsForTesting()
        await probe.installFileFaultPlanForTesting(nil)
        try await probe.close()
        let writes: [UInt64] = operations.compactMap { (operation: FDFileOperation) -> UInt64? in
            if case .pwrite(let offset, _) = operation { return offset }
            return nil
        }
        return try #require(writes.lastIndex { (offset: UInt64) -> Bool in offset < Constants.headerRegionSize })
    }
}

@Test func importCommitFailingAfterItsFooterSyncedLeavesTheOutcomeToTheNextOpen() async throws {
    let range = 0..<200
    let writesBeforeHeader = try await pwritesBeforeImportCommitHeader(range)
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        #expect(try await wax.beginFrameImport())
        _ = try await importRange(range, into: wax)
        let importedRanges = await wax.frameImportPayloadRangesForTesting()
        #expect(!importedRanges.isEmpty)

        // Every write up to the header goes through (a full-length "short" write is a plain
        // write); the header write fails after the footer synced.
        let faults: [FDFileWriteFault] = Array(repeating: .shortWrite(maxBytes: .max), count: writesBeforeHeader) + [.eio]
        await wax.installFileFaultPlanForTesting(FDFileFaultPlan(pwrite: faults))
        await #expect(throws: (any Error).self) { try await wax.commitFrameImport() }
        await wax.installFileFaultPlanForTesting(nil)
        let freeBefore = await freeBytes(wax)
        await wax.abandonFrameImport()

        // A footer scan may recover the failed commit: its payloads stay reserved, and writes
        // that would reuse its frame ids are refused until the store is reopened.
        #expect(await freeBytes(wax) == freeBefore)
        await #expect(throws: (any Error).self) {
            _ = try await wax.put(noisePayload(0), options: FrameMetaSubset(role: .document))
        }
        await #expect(throws: (any Error).self) {
            try await wax.putEmbedding(frameId: 0, vector: importVector(0))
        }
        await #expect(throws: (any Error).self) { try await wax.commit() }
        #expect(await wax.frameMetas().count == 1, "reads still see the last commit")
        let crashed = TempFiles.uniqueURL()
        defer { try? FileManager.default.removeItem(at: crashed) }
        try FileManager.default.copyItem(at: url, to: crashed)
        try await wax.close()
        #expect(try Data(contentsOf: url) == Data(contentsOf: crashed), "close wrote nothing")

        let reopened = try await Wax.open(at: url)
        try await reopened.verify(deep: true)
        let frameCount = await reopened.stats().frameCount
        #expect(frameCount == 1 || frameCount == UInt64(range.count + 1))
        if frameCount > 1 {
            #expect(try await reopened.frameContent(frameId: 1) == importPayload(0))
            #expect(try await reopened.frameContent(frameId: UInt64(range.count)) == importPayload(range.count - 1))
        }
        let later = try await reopened.put(noisePayload(1), options: FrameMetaSubset(role: .document))
        #expect(later == frameCount)
        try await reopened.commit()
        try await reopened.close()
        let again = try await Wax.open(at: url)
        try await again.verify(deep: true)
        #expect(await again.stats().frameCount == frameCount + 1)
        try await again.close()
    }
}

@Test func memoryBindingWritesWaitForAnOpenFrameImport() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        #expect(try await wax.beginFrameImport())
        _ = try await importRange(0..<5, into: wax)

        let binding = MemoryBinding(embeddingProvider: "Test", embeddingModel: "Import", embeddingDimensions: 8)
        let setBinding = Task { () async throws -> Void in
            try await wax.setMemoryBindingIfMissing(binding)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while await wax.frameImportWaiterCountForTesting() < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await wax.frameImportWaiterCountForTesting() == 1, "the binding write waits for the import")
        #expect(await wax.memoryBinding() == nil)

        try await wax.commitFrameImport()
        try await setBinding.value
        #expect(await wax.memoryBinding() == binding)
        try await wax.commit()
        try await wax.close()
    }
}

@Test func frameImportRefusesABatchThatCannotFitTheCommit() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await seededStore(url)
        #expect(try await wax.beginFrameImport())
        _ = try await importRange(0..<10, into: wax)
        let rangesBefore = await wax.frameImportPayloadRangesForTesting()

        // Each frame's text alone is more than 15 bytes: 100 of them fit neither 1,000 bytes
        // of text index nor a TOC with room for 1,000 bytes more.
        await wax.setFrameImportLimitsForTesting(tocBytes: .max, lexBytes: 1_000)
        await #expect(throws: (any Error).self) {
            _ = try await wax.importFrames((10..<110).map(importPayload), options: importOptions(10..<110))
        }
        #expect(await wax.frameImportPayloadRangesForTesting() == rangesBefore, "nothing of the batch was written")

        let tocBytes = await wax.frameImportTocBytesLowerBoundForTesting()
        await wax.setFrameImportLimitsForTesting(tocBytes: tocBytes + 1_000, lexBytes: .max)
        await #expect(throws: (any Error).self) {
            _ = try await wax.importFrames((10..<110).map(importPayload), options: importOptions(10..<110))
        }
        #expect(await wax.frameImportPayloadRangesForTesting() == rangesBefore)

        await wax.setFrameImportLimitsForTesting(tocBytes: .max, lexBytes: .max)
        let ids = try await importRange(10..<20, into: wax)
        #expect(ids.first == 11)
        try await wax.commitFrameImport()
        #expect(await wax.stats().frameCount == 21)
        try await wax.close()
    }
}
