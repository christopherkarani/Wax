import Foundation
import Testing
@testable import Wax

@Test
func sessionRuntimeStatsIgnoresDeletedSupersededAndPendingSessionFrames() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let sessionID = await orchestrator.startSession().uuidString
        let wax = await orchestrator.wax

        let active = try await wax.put(
            Data("session active frame".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["session_id": sessionID])
            )
        )

        let superseded = try await wax.put(
            Data("session superseded frame".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["session_id": sessionID])
            )
        )
        let replacement = try await wax.put(
            Data("session replacement frame".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["session_id": sessionID])
            )
        )
        try await wax.supersede(supersededId: superseded, supersedingId: replacement)

        let deleted = try await wax.put(
            Data("session deleted frame".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["session_id": sessionID])
            )
        )
        try await wax.delete(frameId: deleted)
        try await wax.commit()

        _ = try await wax.put(
            Data("session pending frame".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["session_id": sessionID])
            )
        )

        let stats = try await orchestrator.sessionRuntimeStats()
        let tokenCounter = try await TokenCounter.shared()
        let expectedTokens = await tokenCounter.countBatch([
            "session active frame",
            "session replacement frame",
        ]).reduce(0, +)

        #expect(stats.active)
        #expect(stats.sessionId?.uuidString == sessionID)
        #expect(stats.sessionFrameCount == 2)
        #expect(stats.sessionTokenEstimate == expectedTokens)
        #expect(stats.pendingFramesStoreWide == 1)
        #expect(stats.countsIncludePending == false)
        #expect(active == 0)
        #expect(replacement > superseded)

        try await orchestrator.close()
    }
}
