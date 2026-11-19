import Foundation
import Testing
@testable import Wax

/// Parks every embed of a text containing "park" until released.
private actor BatchParkingEmbedder: EmbeddingProvider {
    nonisolated let dimensions = 2
    nonisolated let normalize = true
    nonisolated let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Mock",
        model: "BatchParking",
        dimensions: 2,
        normalized: true
    )
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func embed(_ text: String) async throws -> [Float] {
        if text.contains("park"), !released {
            await withCheckedContinuation { parked.append($0) }
        }
        return [1, 0]
    }

    func hasParked() -> Bool { !parked.isEmpty }

    func release() {
        released = true
        let waiting = parked
        parked.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private func isClosedSessionError(_ error: any Error) -> Bool {
    String(describing: error).contains("session is closed")
}

/// A batch save in flight when `close()` starts is waited for, so its documents are
/// durable after reopen instead of written to a closing store. The multi-chunk document
/// is written after the parked run, once close has begun, and must still be admitted.
@Test
func batchSaveInFlightWhenCloseStartsIsDrainedAndDurable() async throws {
    try await TempFiles.withTempFile { url in
        let config = TestHelpers.defaultMemoryConfig(vector: true)
        let embedder = BatchParkingEmbedder()
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        let multiChunk = (0..<40).map { "word\($0)" }.joined(separator: " ")
        let texts = ["park batch alpha", "park batch beta", multiChunk]
        let save = Task {
            try await orchestrator.remember(batch: texts.map { (text: $0, metadata: [:]) })
        }
        while !(await embedder.hasParked()) { await Task.yield() }

        let close = Task { try await orchestrator.close() }
        let deadline = ContinuousClock.now + .seconds(10)
        var closeWaitedForTheBatch = false
        while ContinuousClock.now < deadline {
            if await orchestrator.isWaitingForWritesToDrainForTesting() {
                closeWaitedForTheBatch = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(closeWaitedForTheBatch, "close() must wait for the batch save it admitted")
        await embedder.release()
        let ids = try await save.value
        try await close.value
        #expect(ids.count == texts.count)

        let reopened = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        let active = await reopened.wax.frameMetas().filter { $0.status == .active && $0.role == .document }
        #expect(Set(active.map(\.id)) == Set(ids))
        try await reopened.close()
    }
}

/// Batch saves and imports that start after `close()` began are refused like single saves.
@Test
func batchSaveAndImportAfterCloseAreRefused() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: TestHelpers.defaultMemoryConfig(vector: false)
        )
        try await orchestrator.close()

        await #expect(performing: {
            _ = try await orchestrator.remember(batch: [(text: "late batch", metadata: [:])])
        }, throws: isClosedSessionError)
        await #expect(performing: {
            _ = try await orchestrator.importDocuments([(text: "late import", metadata: [:])])
        }, throws: isClosedSessionError)
    }
}
