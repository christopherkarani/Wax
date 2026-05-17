import Foundation
import Testing
@testable import Wax

@Test
func corpusSourceDocumentsExcludesSupersededActiveDocuments() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let wax = await orchestrator.wax

        let oldID = try await wax.put(
            Data("old superseded corpus document".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["fixture": "old"])
            )
        )
        let replacementID = try await wax.put(
            Data("new replacement corpus document".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata(["fixture": "replacement"])
            )
        )
        try await wax.commit()

        try await wax.supersede(supersededId: oldID, supersedingId: replacementID)
        try await wax.commit()

        let exported = try await orchestrator.corpusSourceDocuments()
        #expect(!exported.contains { $0.frameId == oldID })
        #expect(exported.contains { $0.frameId == replacementID })
        #expect(!exported.contains { $0.text == "old superseded corpus document" })

        try await orchestrator.close()
    }
}
