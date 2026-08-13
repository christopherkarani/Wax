import Foundation
import Testing
@testable import WaxCore

@Test func walRingWriterTracksWrapCheckpointAndSentinelCounters() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }
        try file.truncate(to: 1024)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 256)
        let payload = Data(repeating: 0xAB, count: 20)

        _ = try writer.append(payload: payload)
        _ = try writer.append(payload: payload)
        writer.recordCheckpoint()
        _ = try writer.append(payload: payload)
        _ = try writer.append(payload: payload)

        #expect(writer.wrapCount == 1)
        #expect(writer.checkpointCount == 1)
        #expect(writer.sentinelWriteCount == 4)
        #expect(writer.writeCallCount < 9)
    }
}

@Test func walRingWriterInlinesContiguousSentinelWrite() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }
        try file.truncate(to: 2048)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 1024)
        let payload = Data(repeating: 0xA5, count: 64)

        _ = try writer.append(payload: payload)

        #expect(writer.sentinelWriteCount == 1)
        #expect(writer.writeCallCount == 1)
    }
}

@Test func walRingWriterCoalescesBatchOperationsIntoSingleWrite() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }
        try file.truncate(to: 4096)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 2048)
        let payloads = (0..<5).map { index in
            Data(repeating: UInt8(40 + index), count: 80)
        }

        let sequences = try writer.appendBatch(payloads: payloads)
        #expect(sequences.count == payloads.count)
        #expect(writer.sentinelWriteCount == 1)
        #expect(writer.writeCallCount == 1)
    }
}

@Test func waxWalStatsExposeCheckpointAndSequenceProgress() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 8 * 1024)
    _ = try await wax.put(
        Data("checkpoint-progress".utf8),
        options: FrameMetaSubset(searchText: "checkpoint-progress")
    )

    let beforeCommit = await wax.walStats()
    #expect(beforeCommit.pendingBytes > 0)
    #expect(beforeCommit.checkpointCount == 0)

    try await wax.commit()
    let afterCommit = await wax.walStats()

    #expect(afterCommit.pendingBytes == 0)
    #expect(afterCommit.checkpointCount == 1)
    #expect(afterCommit.committedSeq > 0)
    #expect(afterCommit.lastSeq >= afterCommit.committedSeq)

    try await wax.commit()
    let afterNoOpCommit = await wax.walStats()
    #expect(afterNoOpCommit.checkpointCount == afterCommit.checkpointCount)

    try await wax.close()
}

@Test func waxWalStatsTracksCapacityTriggeredAutoCommits() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 2 * 1024)
    var observedAutoCommit = false

    for index in 0..<256 {
        let payload = Data(repeating: UInt8(index % 251), count: 128)
        _ = try await wax.put(
            payload,
            options: FrameMetaSubset(searchText: "auto-commit-\(index)")
        )

        let stats = await wax.walStats()
        if stats.autoCommitCount > 0 {
            observedAutoCommit = true
            #expect(stats.checkpointCount > 0)
            #expect(stats.committedSeq > 0)
            break
        }
    }

    #expect(observedAutoCommit)
    let finalStats = await wax.walStats()
    #expect(finalStats.autoCommitCount > 0)
    #expect(finalStats.pendingBytes <= finalStats.walSize)
    #expect(finalStats.lastSeq >= finalStats.committedSeq)

    try await wax.close()
}

@Test func waxProactiveWalPressureAutoCommitTriggersBeforeCapacityEdge() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(
        at: url,
        walSize: 256 * 1024,
        options: WaxOptions(
            walProactiveCommitThresholdPercent: 10,
            walProactiveCommitMaxWalSizeBytes: nil,
            walProactiveCommitMinPendingBytes: 4 * 1024
        )
    )

    for index in 0..<256 {
        let payload = Data(repeating: UInt8(index % 251), count: 128)
        _ = try await wax.put(
            payload,
            options: FrameMetaSubset(searchText: "pressure-proactive-\(index)")
        )
    }

    let stats = await wax.walStats()
    #expect(stats.autoCommitCount > 0)
    #expect(stats.checkpointCount > 0)

    try await wax.close()
}

@Test func waxPutBatchCommitsUnderWalPressureForOversizedSequentialFrames() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 4 * 1024 * 1024)
    let firstSearchText = String(repeating: "a", count: 2_060_043)
    let secondSearchText = String(repeating: "b", count: 2_166_825)

    _ = try await wax.putBatch(
        [Data("frame-1".utf8), Data("frame-2".utf8)],
        options: [
            FrameMetaSubset(searchText: firstSearchText),
            FrameMetaSubset(searchText: secondSearchText)
        ]
    )

    let stats = await wax.walStats()
    #expect(stats.autoCommitCount > 0)
    #expect(stats.pendingBytes <= stats.walSize)
    #expect(stats.checkpointCount > 0)

    try await wax.close()
}

@Test func waxCommitsUnderWalPressureForOversizedSingleFrames() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 4 * 1024 * 1024)
    let searchText = String(repeating: "x", count: 2_166_825)

    _ = try await wax.put(
        Data("frame-1".utf8),
        options: FrameMetaSubset(searchText: searchText)
    )
    _ = try await wax.put(
        Data("frame-2".utf8),
        options: FrameMetaSubset(searchText: searchText)
    )

    let stats = await wax.walStats()
    #expect(stats.autoCommitCount > 0)
    #expect(stats.pendingBytes <= stats.walSize)
    #expect(stats.checkpointCount > 0)

    try await wax.close()
}

@Test func waxCommitsUnderWalPressureWhenEmbeddingsArePending() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 4 * 1024 * 1024)
    await wax.setWalPressureIndexPreparer { [weak wax] in
        guard let wax else { return }
        let embeddings = await wax.pendingEmbeddingMutations()
        guard let first = embeddings.first else { return }
        var vectors: [Float] = []
        var frameIds: [UInt64] = []
        for embedding in embeddings {
            vectors.append(contentsOf: embedding.vector)
            frameIds.append(embedding.frameId)
        }
        let bytes = validFlatVecIndexSegment(
            vectors: vectors,
            frameIds: frameIds,
            dimension: first.dimension,
            similarity: .cosine
        )
        try await wax.stageVecIndexForNextCommit(
            bytes: bytes,
            vectorCount: UInt64(frameIds.count),
            dimension: first.dimension,
            similarity: .cosine
        )
    }

    let firstId = try await wax.put(
        Data("embed-pressure-seed".utf8),
        options: FrameMetaSubset(searchText: "embed-pressure-seed")
    )
    try await wax.putEmbedding(frameId: firstId, vector: [0.1, 0.2])

    var autoCommits: UInt64 = 0
    for index in 0..<800 {
        let text = "embed-pressure-\(index)-" + String(repeating: "x", count: 8_192)
        let frameId = try await wax.put(
            Data("embed-pressure-\(index)".utf8),
            options: FrameMetaSubset(searchText: text)
        )
        autoCommits = (await wax.walStats()).autoCommitCount
        if autoCommits > 0 { break }
        try await wax.putEmbedding(frameId: frameId, vector: [0.1, 0.2])
    }

    let stats = await wax.walStats()
    #expect(stats.autoCommitCount > 0)
    #expect(stats.pendingBytes <= stats.walSize)
    #expect(stats.checkpointCount > 0)

    try await wax.close()

    let reopened = try await Wax.open(at: url)
    let texts = Set((await reopened.frameMetas()).compactMap(\.searchText))
    #expect(texts.contains("embed-pressure-seed"))
    try await reopened.close()
}

@Test func waxWalPressureAutoCommitCanBeDisabled() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(
        at: url,
        walSize: 256 * 1024,
        options: WaxOptions(walProactiveCommitThresholdPercent: nil)
    )

    for index in 0..<256 {
        let payload = Data(repeating: UInt8(index % 251), count: 128)
        _ = try await wax.put(
            payload,
            options: FrameMetaSubset(searchText: "pressure-disabled-\(index)")
        )
    }

    let stats = await wax.walStats()
    #expect(stats.autoCommitCount == 0)
    #expect(stats.checkpointCount == 0)

    try await wax.close()
}

@Test func waxDefaultProactiveCommitTargetsSmallWalOnly() async throws {
    let smallWalURL = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: smallWalURL) }
    let smallWal = try await Wax.create(at: smallWalURL, walSize: 512 * 1024)

    for index in 0..<3_000 {
        let payload = Data(repeating: UInt8(index % 251), count: 128)
        _ = try await smallWal.put(
            payload,
            options: FrameMetaSubset(searchText: "default-small-\(index)")
        )
    }
    let smallWalStats = await smallWal.walStats()
    #expect(smallWalStats.autoCommitCount > 0)
    try await smallWal.close()

    let largeWalURL = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: largeWalURL) }
    let largeWal = try await Wax.create(at: largeWalURL, walSize: 8 * 1024 * 1024)

    for index in 0..<3_000 {
        let payload = Data(repeating: UInt8(index % 251), count: 128)
        _ = try await largeWal.put(
            payload,
            options: FrameMetaSubset(searchText: "default-large-\(index)")
        )
    }
    let largeWalStats = await largeWal.walStats()
    #expect(largeWalStats.autoCommitCount == 0)
    try await largeWal.close()
}

@Test func waxWalStatsExposeReplaySnapshotHitsOnReopen() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(
            at: url,
            walSize: 512 * 1024,
            options: WaxOptions(walReplayStateSnapshotEnabled: true)
        )
        _ = try await wax.put(
            Data("snapshot-hit".utf8),
            options: FrameMetaSubset(searchText: "snapshot-hit")
        )
        try await wax.commit()
        try await wax.close()
    }

    let reopened = try await Wax.open(
        at: url,
        options: WaxOptions(walReplayStateSnapshotEnabled: true)
    )
    let stats = await reopened.walStats()
    #expect(stats.replaySnapshotHitCount > 0)
    try await reopened.close()
}

private func validFlatVecIndexSegment(
    vectors: [Float],
    frameIds: [UInt64],
    dimension: UInt32,
    similarity: VecSimilarity
) -> Data {
    var data = Data([0x4D, 0x56, 0x32, 0x56])
    var version = UInt16(1).littleEndian
    withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
    data.append(3)
    data.append(similarity.rawValue)
    var dimensionLE = dimension.littleEndian
    withUnsafeBytes(of: &dimensionLE) { data.append(contentsOf: $0) }
    var vectorCountLE = UInt64(frameIds.count).littleEndian
    withUnsafeBytes(of: &vectorCountLE) { data.append(contentsOf: $0) }
    var payloadLength = UInt64(vectors.count * MemoryLayout<Float>.stride).littleEndian
    withUnsafeBytes(of: &payloadLength) { data.append(contentsOf: $0) }
    data.append(Data(repeating: 0, count: 8))
    vectors.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    var frameIdLength = UInt64(frameIds.count * MemoryLayout<UInt64>.stride).littleEndian
    withUnsafeBytes(of: &frameIdLength) { data.append(contentsOf: $0) }
    frameIds.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    return data
}
