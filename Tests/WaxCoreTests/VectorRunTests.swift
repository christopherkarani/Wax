import Foundation
import Testing
@testable import WaxCore

// MARK: - Helpers

private func vector(_ frame: Int, version: Int = 0, dimension: Int = 4) -> [Float] {
    (0..<dimension).map { Float(frame + 1) * 0.5 + Float($0) * 0.25 + Float(version) * 10 }
}

private func committedMap(_ wax: Wax) async throws -> [UInt64: [Float]] {
    guard let committed = try await wax.readCommittedVectors() else { return [:] }
    let dimension = Int(committed.dimension)
    var map: [UInt64: [Float]] = [:]
    for (row, frameId) in committed.frameIds.enumerated() {
        #expect(map[frameId] == nil, "frame \(frameId) appears twice")
        map[frameId] = Array(committed.vectors[(row * dimension)..<((row + 1) * dimension)])
    }
    return map
}

private func putFrames(_ wax: Wax, count: Int) async throws {
    for index in 0..<count {
        _ = try await wax.put(Data("frame \(index)".utf8))
    }
}

private func headerFormatVersions(_ url: URL) throws -> [UInt16] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let pages = try handle.read(upToCount: 8192) ?? Data()
    return [0, 4096].map { offset in
        UInt16(pages[offset + 4]) | (UInt16(pages[offset + 5]) << 8)
    }
}

// MARK: - Run codec

@Test func vecRunRoundtripsRowsAndTombstones() throws {
    let run = VecRun(
        dimension: 2,
        similarity: .dot,
        frameIds: [9, 3],
        vectors: [1, 2, 3, 4],
        tombstones: [5, 7]
    )
    let bytes = try VecRunCodec.encode(run)
    #expect(try VecRunCodec.decode(bytes) == run)
    let header = try VecRunCodec.decodeHeader(bytes)
    #expect(header.version == 2)
    #expect(header.rowCount == 2)
    #expect(header.tombstoneCount == 2)
}

@Test func vecRunRejectsATombstoneThatIsAlsoARow() {
    let run = VecRun(dimension: 1, similarity: .cosine, frameIds: [1], vectors: [1], tombstones: [1])
    #expect(throws: WaxError.self) { try VecRunCodec.encode(run) }
}

@Test func aV1VectorBlobDecodesAsARunWithoutTombstones() throws {
    // The v1 whole-index layout: reserved zero bytes where a run keeps its tombstone count.
    var blob = Data([0x4D, 0x56, 0x32, 0x56])
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { blob.append(contentsOf: $0) }
    }
    append(UInt16(1))
    blob.append(3)
    blob.append(0)
    append(UInt32(2))
    append(UInt64(1))
    append(UInt64(8))
    blob.append(contentsOf: [UInt8](repeating: 0, count: 8))
    [Float(0.5), -1].withUnsafeBytes { blob.append(contentsOf: $0) }
    append(UInt64(8))
    append(UInt64(77))

    let run = try VecRunCodec.decode(blob)
    #expect(run == VecRun(dimension: 2, similarity: .cosine, frameIds: [77], vectors: [0.5, -1], tombstones: []))
    #expect(try VecRunCodec.decodeHeader(blob).version == 1)
}

// MARK: - Commits

@Test func aCommitWritesOnlyTheVectorsSinceThePreviousCommit() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: 101)
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
        try await wax.putEmbeddingBatch(frameIds: (0..<100).map(UInt64.init), vectors: (0..<100).map { vector($0) })
        try await wax.commit()

        try await wax.putEmbedding(frameId: 100, vector: vector(100))
        try await wax.commit()

        let manifest = try #require(await wax.committedVecIndexManifest())
        #expect(manifest.vectorCount == 101)
        #expect(manifest.runs.map(\.rowCount) == [100, 1])
        #expect(manifest.runs.map(\.level) == [0, 0])
        // The second run holds one row: header, 4 floats, the key count and one key.
        #expect(manifest.runs[1].bytesLength == 36 + 16 + 8 + 8)
        let vecEntries = await wax.segmentCatalogEntriesForTesting().filter { $0.kind == .vec }
        #expect(vecEntries.count == 2)
        try await wax.verify(deep: true)
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let map = try await committedMap(reopened)
        #expect(map.count == 101)
        let last: [Float]? = map[100]
        let first: [Float]? = map[0]
        #expect(last == vector(100))
        #expect(first == vector(0))
        try await reopened.close()
    }
}

/// Runs are read and verified concurrently; a damaged run that is neither first nor last
/// must still fail the read with a checksum mismatch.
@Test func aDamagedMiddleRunFailsTheCommittedVectorRead() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: 30)
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
        for batch in 0..<3 {
            let ids = (batch * 10..<(batch + 1) * 10).map(UInt64.init)
            try await wax.putEmbeddingBatch(frameIds: ids, vectors: ids.map { vector(Int($0)) })
            try await wax.commit()
        }
        let manifest = try #require(await wax.committedVecIndexManifest())
        #expect(manifest.runs.count == 3)
        let middle = manifest.runs[1]
        #expect(try await committedMap(wax).count == 30)
        try await wax.close()

        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: middle.bytesOffset + middle.bytesLength / 2)
        let original = try #require(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: middle.bytesOffset + middle.bytesLength / 2)
        try handle.write(contentsOf: Data([original ^ 0xFF]))
        try handle.close()

        let reopened = try await Wax.open(at: url)
        await #expect {
            _ = try await reopened.readCommittedVectors()
        } throws: { error in
            guard case WaxError.checksumMismatch = error else { return false }
            return true
        }
        try await reopened.close()
    }
}

@Test func committedVectorsApplyReplacementsRemovalsAndReAdds() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: 21)
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .dot)
        // Twenty rows, so two dead rows stay under the fifth that merges every run.
        try await wax.putEmbeddingBatch(frameIds: (0..<20).map(UInt64.init), vectors: (0..<20).map { vector($0) })
        try await wax.commit()

        try await wax.putEmbedding(frameId: 1, vector: vector(1, version: 1))
        try await wax.removeEmbedding(frameId: 2)
        try await wax.removeEmbedding(frameId: 20) // never had a vector: no tombstone
        try await wax.commit()

        var expected = Dictionary(uniqueKeysWithValues: (0..<20).map { (UInt64($0), vector($0)) })
        expected[1] = vector(1, version: 1)
        expected[2] = nil
        var manifest = try #require(await wax.committedVecIndexManifest())
        #expect(manifest.runs.count == 2)
        #expect(manifest.vectorCount == 19)
        #expect(manifest.runs.last?.rowCount == 1)
        #expect(manifest.runs.last?.tombstoneCount == 1)
        #expect(try await committedMap(wax) == expected)
        #expect(try await wax.committedVectorFrameIds() == Set(expected.keys))

        try await wax.putEmbedding(frameId: 2, vector: vector(2, version: 2))
        try await wax.commit()
        expected[2] = vector(2, version: 2)
        manifest = try #require(await wax.committedVecIndexManifest())
        #expect(manifest.vectorCount == 20)
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        #expect(try await committedMap(reopened) == expected)
        #expect(try await reopened.committedVectorFrameIds() == Set(expected.keys))
        try await reopened.verify(deep: true)
        try await reopened.close()
    }
}

@Test func aVectorPutAndRemovedBeforeItsCommitWritesNoRun() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: 2)
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
        try await wax.putEmbedding(frameId: 0, vector: vector(0))
        try await wax.commit()
        let before = try #require(await wax.committedVecIndexManifest())

        try await wax.putEmbedding(frameId: 1, vector: vector(1))
        try await wax.removeEmbedding(frameId: 1)
        try await wax.commit()

        #expect(await wax.committedVecIndexManifest() == before)
        try await wax.close()
    }
}

@Test func committingVectorsWithoutAConfigurationOrCommittedIndexThrows() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: 1)
        try await wax.putEmbedding(frameId: 0, vector: vector(0))
        await #expect(throws: WaxError.self) { try await wax.commit() }
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
        try await wax.commit()
        #expect(await wax.committedVecIndexManifest()?.vectorCount == 1)
        try await wax.close()
    }
}

@Test func theVectorConfigurationMustMatchTheCommittedIndex() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: 1)
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
        try await wax.putEmbedding(frameId: 0, vector: vector(0))
        try await wax.commit()

        await #expect(throws: WaxError.self) {
            try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .dot)
        }
        await #expect(throws: WaxError.self) {
            try await wax.setVectorIndexConfiguration(dimension: 3, similarity: .cosine)
        }
        await #expect(throws: WaxError.self) {
            try await wax.putEmbedding(frameId: 0, vector: [1, 2, 3])
        }
        try await wax.close()
    }
}

// MARK: - Merging

@Test func eightLevelZeroRunsMergeIntoOneRunALevelUp() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: 16)
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
        for commit in 0..<7 {
            try await wax.putEmbedding(frameId: UInt64(commit), vector: vector(commit))
            try await wax.commit()
        }
        var manifest = try #require(await wax.committedVecIndexManifest())
        #expect(manifest.runs.count == 7)
        let mergedAway = manifest.runs.map { $0.bytesOffset..<($0.bytesOffset + $0.bytesLength) }

        try await wax.putEmbedding(frameId: 7, vector: vector(7))
        try await wax.commit()
        manifest = try #require(await wax.committedVecIndexManifest())
        #expect(manifest.runs.count == 1)
        #expect(manifest.runs[0].level == 1)
        #expect(manifest.runs[0].rowCount == 8)
        #expect(await wax.segmentCatalogEntriesForTesting().filter { $0.kind == .vec }.count == 1)
        // The merged-away runs are free once the merge's header is durable (or cut off with
        // the file's tail).
        let free = await wax.freeDataRangesForTesting()
        let fileSize = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).uint64Value
        for range in mergedAway {
            #expect(
                range.lowerBound >= fileSize
                    || free.contains { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }
            )
        }
        #expect(try await committedMap(wax) == Dictionary(uniqueKeysWithValues: (0..<8).map { (UInt64($0), vector($0)) }))
        try await wax.verify(deep: true)
        try await wax.close()
    }
}

/// The commit that replaces more than a fifth of the rows merges every run, including the rows
/// it adds: they go straight into the merged run, which is written once.
@Test func aCommitThatReplacesMoreThanAFifthOfTheRowsWritesItsRowsOnceIntoTheMergedRun() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: 10)
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
        try await wax.putEmbeddingBatch(frameIds: (0..<10).map(UInt64.init), vectors: (0..<10).map { vector($0) })
        try await wax.commit()
        let first = try #require(await wax.committedVecIndexManifest()?.runs.first)

        try await wax.putEmbeddingBatch(frameIds: [0, 1, 2], vectors: (0..<3).map { vector($0, version: 1) })
        await wax.installFileFaultPlanForTesting(FDFileFaultPlan(recordsOperations: true))
        try await wax.commit()
        let operations = await wax.recordedFileOperationsForTesting()
        await wax.installFileFaultPlanForTesting(nil)

        let manifest = try #require(await wax.committedVecIndexManifest())
        #expect(manifest.runs.count == 1)
        #expect(manifest.runs[0].rowCount == 10)
        #expect(manifest.runs[0].level == 1)
        #expect(manifest.vectorCount == 10)
        // One run write: the merged run. The commit's three rows are not written on their own.
        let rowBytes = 4 * MemoryLayout<Float>.stride + MemoryLayout<UInt64>.stride
        let runSize: Int = 36 + 10 * rowBytes + 8
        let commitRowsRunSize: Int = 36 + 3 * rowBytes + 8
        #expect(manifest.runs[0].bytesLength == UInt64(runSize))
        let runWrites = operations.filter { operation in
            guard case .pwrite(_, let length) = operation else { return false }
            return length == commitRowsRunSize || length == runSize
        }
        #expect(runWrites == [.pwrite(offset: manifest.runs[0].bytesOffset, length: runSize)])
        #expect(manifest.runs[0].bytesOffset != first.bytesOffset)
        var expected = Dictionary(uniqueKeysWithValues: (0..<10).map { (UInt64($0), vector($0)) })
        for frame in 0..<3 { expected[UInt64(frame)] = vector(frame, version: 1) }
        #expect(try await committedMap(wax) == expected)
        try await wax.verify(deep: true)
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        #expect(try await committedMap(reopened) == expected)
        try await reopened.close()
    }
}

@Test func replacingMoreThanAFifthOfTheRowsMergesEveryRun() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: 10)
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
        try await wax.putEmbeddingBatch(frameIds: (0..<10).map(UInt64.init), vectors: (0..<10).map { vector($0) })
        try await wax.commit()
        // Two of twelve rows dead: no merge yet.
        try await wax.putEmbeddingBatch(frameIds: [0, 1], vectors: [vector(0, version: 1), vector(1, version: 1)])
        try await wax.commit()
        #expect(await wax.committedVecIndexManifest()?.runs.count == 2)
        // Three of thirteen dead, then: every run merges into one.
        try await wax.removeEmbedding(frameId: 2)
        try await wax.commit()

        let manifest = try #require(await wax.committedVecIndexManifest())
        #expect(manifest.runs.count == 1)
        #expect(manifest.runs[0].rowCount == 9)
        #expect(manifest.runs[0].tombstoneCount == 0)
        #expect(manifest.vectorCount == 9)
        var expected = Dictionary(uniqueKeysWithValues: (3..<10).map { (UInt64($0), vector($0)) })
        expected[0] = vector(0, version: 1)
        expected[1] = vector(1, version: 1)
        #expect(try await committedMap(wax) == expected)
        try await wax.close()
    }
}

@Test func runsMatchAModelOfEveryChangeAcrossCommitsMergesAndReopens() async throws {
    try await TempFiles.withTempFile { url in
        var wax = try await Wax.create(at: url)
        let frameCount = 60
        try await putFrames(wax, count: frameCount)
        try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .dot)
        var model: [UInt64: [Float]] = [:]
        var rng = RunTestRandom(seed: 0x5EED)
        for round in 0..<70 {
            for _ in 0..<(1 + Int(rng.next() % 6)) {
                let frame = UInt64(rng.next() % UInt64(frameCount))
                if rng.next() % 4 == 0 {
                    try await wax.removeEmbedding(frameId: frame)
                    model[frame] = nil
                } else {
                    let values = vector(Int(frame), version: round)
                    try await wax.putEmbedding(frameId: frame, vector: values)
                    model[frame] = values
                }
            }
            try await wax.commit()
            #expect(try await committedMap(wax) == model, "round \(round)")
            #expect(try await wax.committedVectorFrameIds() == Set(model.keys), "round \(round)")
            #expect(await wax.committedVecIndexManifest()?.vectorCount == UInt64(model.count))
            if round % 9 == 8 {
                try await wax.verify(deep: true)
                try await wax.close()
                wax = try await Wax.open(at: url)
                #expect(try await committedMap(wax) == model, "reopen after round \(round)")
            }
        }
        let levels = try #require(await wax.committedVecIndexManifest()).runs.map(\.level)
        #expect(levels == levels.sorted(by: >), "levels never increase from older to newer runs")
        try await wax.close()
    }
}

// MARK: - Format version

@Test func headerPagesAcceptFormatVersionsOneTwoThreeAndThreePointOneAndWriteThreePointOne() throws {
    var header = WaxHeaderPage(
        headerPageGeneration: 1,
        fileGeneration: 1,
        footerOffset: Constants.walOffset + Constants.defaultWalSize,
        walOffset: Constants.walOffset,
        walSize: Constants.defaultWalSize,
        walWritePos: 0,
        walCheckpointPos: 0,
        walCommittedSeq: 0,
        tocChecksum: Data(repeating: 0, count: 32)
    )
    #expect(Constants.specVersion == 0x0301)
    let current = try header.encodeWithChecksum()
    #expect(try WaxHeaderPage.decodeWithChecksumValidation(from: current).formatVersion == 0x0301)

    header.formatVersion = 0x0100
    header.specMajor = 1
    header.specMinor = 0
    let legacy = try header.encodeWithChecksum()
    #expect(try WaxHeaderPage.decodeWithChecksumValidation(from: legacy).formatVersion == 0x0100)

    header.formatVersion = 0x0200
    header.specMajor = 2
    let vectorRuns = try header.encodeWithChecksum()
    #expect(try WaxHeaderPage.decodeWithChecksumValidation(from: vectorRuns).formatVersion == 0x0200)

    header.formatVersion = 0x0300
    header.specMajor = 3
    let lexRuns = try header.encodeWithChecksum()
    #expect(try WaxHeaderPage.decodeWithChecksumValidation(from: lexRuns).formatVersion == 0x0300)

    header.formatVersion = 0x0400
    header.specMajor = 4
    #expect(throws: WaxError.self) {
        try WaxHeaderPage.decodeWithChecksumValidation(from: try header.encodeWithChecksum())
    }
}

@Test func aNewStoreWritesFormatVersionThreePointOne() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await wax.close()
        #expect(try headerFormatVersions(url) == [0x0301, 0x0301])
    }
}

// MARK: - Migration from v1

@Test func aV1StoreWithVectorsOpensAndAdoptsItsBlobAsTheFirstRun() async throws {
    let url = try await copyMigrationFixture(named: "migration-v1-vectors")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try headerFormatVersions(url) == [0x0100, 0x0100])

    // Fixture: 40 committed frames with 8-dimension cosine vectors (frame 5 re-embedded once),
    // then pending in the WAL: frame 40, its vector, and frame 7 re-embedded.
    func fixtureVector(_ frame: Int, version: Int = 0) -> [Float] {
        (0..<8).map { Float(frame + 1) * 0.01 + Float($0) * 0.1 + Float(version) }
    }
    var expected = Dictionary(uniqueKeysWithValues: (0..<40).map { (UInt64($0), fixtureVector($0)) })
    expected[5] = fixtureVector(5, version: 1)

    let wax = try await Wax.open(at: url)
    #expect(await wax.stats().frameCount == 40)
    #expect(await wax.stats().pendingFrames == 1)
    #expect(try await committedMap(wax) == expected)
    try await wax.verify(deep: true)
    // Opening and reading leave the file as v1 wrote it.
    #expect(try headerFormatVersions(url) == [0x0100, 0x0100])
    let adopted = try #require(await wax.committedVecIndexManifest())
    #expect(adopted.runs.count == 1)
    #expect(adopted.runs[0].rowCount == 40)
    #expect(adopted.runs[0].keysChecksum == nil)
    #expect(adopted.vectorCount == 40)
    let pending = await wax.pendingEmbeddingMutations(since: nil)
    #expect(Set(pending.embeddings.map(\.frameId)) == [7, 40])
    try await wax.commit()

    let manifest = try #require(await wax.committedVecIndexManifest())
    #expect(manifest.runs.count == 2)
    // The v1 blob stays where it was: adopted in place, not rewritten.
    #expect(manifest.runs[0].bytesOffset == adopted.runs[0].bytesOffset)
    #expect(manifest.runs[0].bytesLength == adopted.runs[0].bytesLength)
    #expect(manifest.runs[0].keysChecksum != nil)
    #expect(manifest.runs[1].rowCount == 2)
    #expect(manifest.vectorCount == 41)
    expected[7] = fixtureVector(7, version: 2)
    expected[40] = fixtureVector(40)
    #expect(try await committedMap(wax) == expected)
    #expect(try await wax.frameContent(frameId: 40) == Data("v1-frame-40".utf8))
    try await wax.close()
    // Both header pages are current now, so a v1 build refuses the file.
    #expect(try headerFormatVersions(url) == [0x0301, 0x0301])

    let reopened = try await Wax.open(at: url)
    #expect(try await committedMap(reopened) == expected)
    #expect(await reopened.stats().frameCount == 41)
    try await reopened.verify(deep: true)
    try await reopened.close()
}

/// A 1.0 build cannot read a removal record in the WAL, so the first removal on a 1.0 file
/// rewrites both header pages first, before any commit.
@Test func theFirstRemovalOnAV1StoreMakesBothHeaderPagesCurrentBeforeItIsLogged() async throws {
    let url = try await copyMigrationFixture(named: "migration-v1-vectors")
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.open(at: url)
    #expect(try headerFormatVersions(url) == [0x0100, 0x0100])
    try await wax.removeEmbedding(frameId: 3)
    #expect(try headerFormatVersions(url) == [0x0301, 0x0301])

    // A crash here: the copy reopens with the removal pending and the v1 commit intact.
    let crashed = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: crashed) }
    try FileManager.default.copyItem(at: url, to: crashed)
    try await wax.close()

    let reopened = try await Wax.open(at: crashed)
    #expect(await reopened.stats().frameCount == 40)
    #expect(await reopened.stats().pendingFrames == 1)
    #expect(await reopened.pendingEmbeddingMutations(since: nil).removedFrameIds == [3])
    #expect(try await reopened.committedVectorFrameIds().contains(3))
    try await reopened.verify(deep: true)
    try await reopened.commit()
    #expect(try await !reopened.committedVectorFrameIds().contains(3))
    try await reopened.close()
}

// MARK: - Stores released builds wrote

private func staleFixtureVector(_ frame: Int, version: Int = 0) -> [Float] {
    (0..<8).map { Float(frame + 1) * 0.01 + Float($0) * 0.1 + Float(version) }
}

/// The fixture's committed vectors: frames 0..<32, frames 5 and 7 re-embedded once.
private func staleFixtureVectors() -> [UInt64: [Float]] {
    var expected = Dictionary(uniqueKeysWithValues: (0..<32).map { (UInt64($0), staleFixtureVector($0)) })
    expected[5] = staleFixtureVector(5, version: 1)
    expected[7] = staleFixtureVector(7, version: 1)
    return expected
}

private func vecCatalogRanges(_ wax: Wax) async -> [Range<UInt64>] {
    await wax.segmentCatalogEntriesForTesting()
        .filter { $0.kind == .vec }
        .map { $0.bytesOffset..<($0.bytesOffset + $0.bytesLength) }
}

/// Released builds (waxmcp 0.1.50 and earlier) appended a vec catalog entry per commit that
/// staged a vector index and never removed the old ones. Such a store opens with its blob
/// adopted as the only run, and its first commit, with or without vectors, drops the stale
/// entries and frees their space once its header is durable.
@Test(arguments: [true, false])
func aV1StoreWithStaleVecCatalogEntriesOpensAndFreesThemAtItsFirstCommit(firstCommitWritesVectors: Bool) async throws {
    let url = try await copyMigrationFixture(named: "migration-v1-stale-vec-entries")
    defer { try? FileManager.default.removeItem(at: url) }
    var expected = staleFixtureVectors()

    let wax = try await Wax.open(at: url)
    #expect(await wax.stats().frameCount == 35)
    #expect(try await committedMap(wax) == expected)
    #expect(try await wax.committedVectorFrameIds() == Set(expected.keys))
    try await wax.verify(deep: true)
    let adopted = try #require(await wax.committedVecIndexManifest()?.runs.first)
    let stale = await vecCatalogRanges(wax).filter { $0.lowerBound != adopted.bytesOffset }
    #expect(stale.count == 2, "the fixture holds the two superseded blobs")

    if firstCommitWritesVectors {
        try await wax.putEmbedding(frameId: 33, vector: staleFixtureVector(33))
        expected[33] = staleFixtureVector(33)
    } else {
        _ = try await wax.put(Data("frame 35".utf8))
    }
    try await wax.commit()

    let manifest = try #require(await wax.committedVecIndexManifest())
    #expect(await vecCatalogRanges(wax) == manifest.runs.map { $0.bytesOffset..<($0.bytesOffset + $0.bytesLength) })
    let free = await wax.freeDataRangesForTesting()
    let fileSize = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).uint64Value
    for range in stale {
        #expect(
            range.lowerBound >= fileSize
                || free.contains { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound },
            "stale vec segment \(range) is free after the first commit"
        )
    }
    #expect(try await committedMap(wax) == expected)
    try await wax.verify(deep: true)
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    #expect(try await committedMap(reopened) == expected)
    try await reopened.verify(deep: true)
    try await reopened.close()
}

/// Photo and video stores remove the vector of every retired frame at each index rebuild,
/// so removing a vector a frame does not have must write nothing: no WAL record, and no
/// header upgrade that would lock released builds out of a store they could still read.
@Test
func removingAVectorAFrameDoesNotHaveWritesNothing() async throws {
    let url = try await copyMigrationFixture(named: "migration-v1-stale-vec-entries")
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.open(at: url)
    let before: WaxWALStats = await wax.walStats()
    for _ in 0..<3 {
        for frameId: UInt64 in 32..<35 {
            try await wax.removeEmbedding(frameId: frameId)
        }
    }
    let after: WaxWALStats = await wax.walStats()
    #expect(after.writePos == before.writePos)
    #expect(after.pendingBytes == 0)
    #expect(await wax.pendingEmbeddingMutations(since: nil).removedFrameIds.isEmpty)
    #expect(try headerFormatVersions(url) == [0x0100, 0x0100], "a no-op removal upgraded the header")
    try await wax.close()
    #expect(try headerFormatVersions(url) == [0x0100, 0x0100])

    // A pending embedding, or a committed vector, still needs its removal record.
    let reopened = try await Wax.open(at: url)
    try await reopened.putEmbedding(frameId: 33, vector: staleFixtureVector(33))
    try await reopened.removeEmbedding(frameId: 33)
    try await reopened.removeEmbedding(frameId: 3)
    #expect(await reopened.pendingEmbeddingMutations(since: nil).removedFrameIds == [3, 33])
    try await reopened.commit()
    var expected = staleFixtureVectors()
    expected[3] = nil
    #expect(try await committedMap(reopened) == expected)
    try await reopened.verify(deep: true)
    try await reopened.close()
}

// MARK: - RNG

private struct RunTestRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Reserving a vector table for a store's runs takes the row counts the runs claim, but
/// never more rows than their bytes, or the data region, can hold.
@Test func vecRunRowCapacityIsBoundedByTheRunsBytes() {
    func run(rows: UInt64, bytes: UInt64) -> VecRunManifest {
        VecRunManifest(
            bytesOffset: 0, bytesLength: bytes, checksum: Data(repeating: 0, count: 32),
            rowCount: rows, tombstoneCount: 0, level: 0, addedGeneration: 0, keysChecksum: nil
        )
    }
    let rowBytes: UInt64 = 4 * 4
    let honest = [run(rows: 10, bytes: 10 * rowBytes + 64), run(rows: 3, bytes: 3 * rowBytes + 64)]
    #expect(Wax.rowCapacity(of: honest, dimension: 4, dataBytes: 1 << 20) == 13)
    // A row count its bytes cannot hold, and counts that would overflow, are capped.
    #expect(Wax.rowCapacity(of: [run(rows: .max, bytes: 5 * rowBytes)], dimension: 4, dataBytes: 1 << 20) == 5)
    let repeated = Array(repeating: run(rows: 1_000, bytes: 1_000 * rowBytes), count: 50)
    #expect(Wax.rowCapacity(of: repeated, dimension: 4, dataBytes: 2_000 * rowBytes) == 2_000)
}

/// A table made from one run holds what applying that run to an empty table holds: rows in
/// order, tombstones a row does not re-add, and (for a run built in memory with a repeated
/// row) the later vector in the first row.
private let runsToAdopt: [VecRun] = [
    VecRun(dimension: 2, similarity: .dot, frameIds: [9, 3, 4], vectors: [1, 2, 3, 4, 5, 6], tombstones: [5, 7]),
    VecRun(dimension: 2, similarity: .dot, frameIds: [], vectors: [], tombstones: [8]),
    VecRun(dimension: 1, similarity: .cosine, frameIds: [2, 6, 2], vectors: [1, 2, 3], tombstones: [6]),
]

@Test(arguments: runsToAdopt)
func vecRunTableMadeFromOneRunMatchesApplyingIt(_ run: VecRun) {
    var applied = VecRunTable(dimension: Int(run.dimension))
    applied.apply(run)
    let adopted = VecRunTable(adopting: run)
    #expect(adopted.dimension == applied.dimension)
    #expect(adopted.frameIds == applied.frameIds)
    #expect(adopted.vectors == applied.vectors)
    #expect(adopted.liveCount == applied.liveCount)
    #expect(adopted.tombstones == applied.tombstones)
    #expect(adopted.compacted() == applied.compacted())
    // Later runs apply to it as to the applied table.
    let next = VecRun(
        dimension: run.dimension,
        similarity: run.similarity,
        frameIds: [3, 11],
        vectors: Array(repeating: 9, count: 2 * Int(run.dimension)),
        tombstones: [9]
    )
    var adoptedThenNext = adopted
    adoptedThenNext.apply(next)
    applied.apply(next)
    #expect(adoptedThenNext.compacted() == applied.compacted())
    #expect(adoptedThenNext.tombstones == applied.tombstones)
}

/// A store whose vectors are one run, large enough to be hashed and decoded at once, reopens
/// with its vectors, and fails the read with a checksum mismatch when the run is damaged in
/// its vectors (which only the hash sees) or its magic (which the decode also rejects).
@Test(arguments: [false, true])
func aDamagedOnlyRunFailsTheCommittedVectorRead(damageHeader: Bool) async throws {
    try await TempFiles.withTempFile { url in
        let dimension = 384
        let count = Wax.concurrentVecRunVerifyBytes / (dimension * 4) + 10
        let wax = try await Wax.create(at: url)
        try await putFrames(wax, count: count)
        try await wax.setVectorIndexConfiguration(dimension: UInt32(dimension), similarity: .dot)
        let ids = (0..<count).map(UInt64.init)
        try await wax.putEmbeddingBatch(frameIds: ids, vectors: ids.map { vector(Int($0), dimension: dimension) })
        try await wax.commit()
        let manifest = try #require(await wax.committedVecIndexManifest())
        #expect(manifest.runs.count == 1)
        let run = try #require(manifest.runs.first)
        #expect(run.bytesLength >= UInt64(Wax.concurrentVecRunVerifyBytes))
        try await wax.close()

        let intact = try await Wax.open(at: url)
        let map = try await committedMap(intact)
        #expect(map.count == count)
        #expect(map[UInt64(count - 1)] == vector(count - 1, dimension: dimension))
        try await intact.close()

        let offset = run.bytesOffset + (damageHeader ? 0 : run.bytesLength / 2)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: offset)
        let original = try #require(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([original ^ 0xFF]))
        try handle.close()

        let reopened = try await Wax.open(at: url)
        await #expect {
            _ = try await reopened.readCommittedVectors()
        } throws: { error in
            guard case WaxError.checksumMismatch = error else { return false }
            return true
        }
        try await reopened.close()
    }
}
