import Foundation
import Testing
@testable import Wax
@testable import WaxCore
import WaxTestSupport

/// A commit that fails at its final fsync leaves the handle refusing further writes, so the
/// flush inside `close()` fails too. `close()` must still release the store: until it does,
/// nothing in this process can reopen the file.
private let failFinalFsync = FDFileFaultPlan(fsync: [.pass, .eio])

private func expectStoreReleased(at url: URL) async throws {
    let reopened = try await Wax.open(at: url, options: WaxOptions(lockWaitTimeout: .milliseconds(500)))
    try await reopened.close()
}

@Test
func memoryOrchestratorCloseReleasesTheStoreAfterALateCommitFailure() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await MemoryOrchestrator(at: url, config: TestHelpers.defaultMemoryConfig(vector: false))
        try await memory.remember("committed before the fault")
        try await memory.flush()
        try await memory.remember("pending when the commit fails")

        await memory.wax.installFileFaultPlanForTesting(failFinalFsync)
        await #expect(throws: (any Error).self) { try await memory.flush() }
        await memory.wax.installFileFaultPlanForTesting(nil)

        await #expect(throws: (any Error).self) { try await memory.close() }
        try await expectStoreReleased(at: url)
    }
}

#if canImport(Darwin)
@Test
func photoOrchestratorCloseReleasesTheStoreAfterALateCommitFailure() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = DeterministicMultimodalEmbedder(
            identity: EmbeddingIdentity(provider: "stub", model: "stub", dimensions: 4, normalized: true)
        )
        let photos = try await PhotoRAGOrchestrator(storeURL: url, config: .default, embedder: embedder)
        _ = try await photos.wax.put(Data("pending when the commit fails".utf8))

        await photos.wax.installFileFaultPlanForTesting(failFinalFsync)
        await #expect(throws: (any Error).self) { try await photos.flush() }
        await photos.wax.installFileFaultPlanForTesting(nil)

        await #expect(throws: (any Error).self) { try await photos.close() }
        try await expectStoreReleased(at: url)
    }
}

@Test
func videoOrchestratorCloseReleasesTheStoreAfterALateCommitFailure() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = DeterministicMultimodalEmbedder(
            identity: EmbeddingIdentity(provider: "stub", model: "stub", dimensions: 4, normalized: true)
        )
        let videos = try await VideoRAGOrchestrator(storeURL: url, config: .default, embedder: embedder)
        _ = try await videos.wax.put(Data("pending when the commit fails".utf8))

        await videos.wax.installFileFaultPlanForTesting(failFinalFsync)
        await #expect(throws: (any Error).self) { try await videos.flush() }
        await videos.wax.installFileFaultPlanForTesting(nil)

        await #expect(throws: (any Error).self) { try await videos.close() }
        try await expectStoreReleased(at: url)
    }
}
#endif
