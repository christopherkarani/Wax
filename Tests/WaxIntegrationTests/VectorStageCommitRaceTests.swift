import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxVectorSearch

/// A remember (`put` with an embedding) issued from inside `WaxSession.commit`, while the
/// commit is between two of its steps. The hook waits until that write either finished or
/// is parked behind the commit, so each run takes the same interleaving.
private actor InterleavedWriter {
    private var task: Task<UInt64, any Error>?
    private var finished = false

    func start(_ operation: @escaping @Sendable () async throws -> UInt64) {
        guard task == nil else { return }
        task = Task {
            do {
                let frameId = try await operation()
                self.markFinished()
                return frameId
            } catch {
                self.markFinished()
                throw error
            }
        }
    }

    func waitUntilFinishedOrParked(on wax: Wax) async {
        while !finished, await wax.embeddingWriteGateWaiterCount() == 0 {
            await Task.yield()
        }
    }

    func value() async throws -> UInt64 {
        guard let task else { throw WaxError.io("interleaved writer never started") }
        return try await task.value
    }

    private func markFinished() {
        finished = true
    }
}

private func vectorOnlyConfig() -> WaxSession.Config {
    var config = WaxSession.Config()
    config.enableTextSearch = false
    config.enableStructuredMemory = false
    config.vectorDimensions = 2
    return config
}

/// Commits once with a remember interleaved at `checkpoint`, then commits the rest, and
/// returns the committed vector count and leftover pending embeddings after reopen.
private func committedVectorsAfterInterleavedRemember(
    at checkpoint: WaxSession.CommitCheckpoint,
    url: URL
) async throws -> (vectorCount: UInt64?, pendingAfterReopen: Int) {
    let wax = try await Wax.create(at: url)
    let session = try await wax.openSession(.readWrite(.fail), config: vectorOnlyConfig())
    _ = try await session.put(Data("first".utf8), embedding: [1, 0])

    let writer = InterleavedWriter()
    await session.setCommitCheckpointHook { reached in
        guard reached == checkpoint else { return }
        await writer.start { try await session.put(Data("second".utf8), embedding: [0, 1]) }
        await writer.waitUntilFinishedOrParked(on: wax)
    }
    try await session.commit()
    await session.setCommitCheckpointHook(nil)
    _ = try await writer.value()

    try await session.commit()
    await session.close()
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    let vectorCount = await reopened.committedVecIndexManifest()?.vectorCount
    let pending = await reopened.pendingEmbeddingMutations().count
    try await reopened.close()
    return (vectorCount, pending)
}

@Test func commitDoesNotFailWhenRememberLandsBetweenStageAndCommit() async throws {
    try await TempFiles.withTempFile { url in
        let result = try await committedVectorsAfterInterleavedRemember(at: .afterStage, url: url)
        #expect(result.vectorCount == 2)
        #expect(result.pendingAfterReopen == 0)
    }
}

@Test func commitKeepsVectorWhenRememberLandsBetweenVectorSyncAndStage() async throws {
    try await TempFiles.withTempFile { url in
        let result = try await committedVectorsAfterInterleavedRemember(at: .afterVectorSync, url: url)
        #expect(result.vectorCount == 2)
        #expect(result.pendingAfterReopen == 0)
    }
}

/// Without a session there is no embedding write gate, so an embedding can land between the
/// engine's sync and its stage. The staged index claims only what the engine synced, so the
/// commit refuses it loudly instead of marking the late embedding committed without its vector.
@Test func directEngineStageAfterLateEmbeddingIsStaleNotSilentlyShort() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let first = try await wax.put(Data("first".utf8))
        try await wax.putEmbedding(frameId: first, vector: [1, 0])
        let engine = try await LoadedVectorSearchEngine.load(
            from: wax,
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )
        let synced = try await WaxVectorSearchSession.syncPendingEmbeddings(wax: wax, into: engine, watermark: nil)

        let second = try await wax.put(Data("second".utf8))
        try await wax.putEmbedding(frameId: second, vector: [0, 1])
        try await engine.stageForCommit(into: wax, syncedThrough: synced)

        do {
            try await wax.commit()
            Issue.record("Expected WaxError.vectorIndexStale")
        } catch let error as WaxError {
            guard case .vectorIndexStale = error else {
                Issue.record("Expected WaxError.vectorIndexStale, got \(error)")
                return
            }
        }

        let resynced = try await WaxVectorSearchSession.syncPendingEmbeddings(wax: wax, into: engine, watermark: synced)
        try await engine.stageForCommit(into: wax, syncedThrough: resynced)
        try await wax.commit()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        #expect(await reopened.committedVecIndexManifest()?.vectorCount == 2)
        #expect(await reopened.pendingEmbeddingMutations().isEmpty)
        try await reopened.close()
    }
}
