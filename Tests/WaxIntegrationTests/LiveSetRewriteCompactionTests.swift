import Foundation
import Testing
import Wax

@Test
func rewriteLiveSetDropsNonLivePayloadsAndPreservesFrameState() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mv2s")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 24, overlapTokens: 4)

        do {
            let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
            let corpus = Array(
                repeating: "Swift concurrency uses actors and tasks for safety and predictable scheduling.",
                count: 24
            ).joined(separator: " ")
            try await orchestrator.remember(corpus)
            try await orchestrator.flush()
            try await orchestrator.close()
        }

        do {
            let wax = try await Wax.open(at: sourceURL)
            let largeDeadPayload = Data(repeating: 0x41, count: 256 * 1024)
            let oldFrame = try await wax.put(
                largeDeadPayload,
                options: FrameMetaSubset(searchText: "old release plan")
            )
            let replacementFrame = try await wax.put(
                Data("replacement frame remains active".utf8),
                options: FrameMetaSubset(searchText: "replacement release plan")
            )
            try await wax.supersede(supersededId: oldFrame, supersedingId: replacementFrame)

            let deletedFrame = try await wax.put(
                largeDeadPayload,
                options: FrameMetaSubset(searchText: "to delete")
            )
            try await wax.delete(frameId: deletedFrame)

            try await wax.commit()
            try await wax.close()
        }

        let report: LiveSetRewriteReport
        do {
            let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
            report = try await orchestrator.rewriteLiveSet(to: destinationURL)
            try await orchestrator.close()
        }

        #expect(report.droppedPayloadFrames >= 2)
        #expect(report.logicalBytesAfter < report.logicalBytesBefore)

        let sourceWax = try await Wax.open(at: sourceURL)
        let rewrittenWax = try await Wax.open(at: destinationURL)

        let sourceMetas = await sourceWax.frameMetas()
        let rewrittenMetas = await rewrittenWax.frameMetas()
        #expect(sourceMetas.count == rewrittenMetas.count)

        for sourceMeta in sourceMetas {
            let rewrittenMeta = rewrittenMetas[Int(sourceMeta.id)]
            #expect(sourceMeta.status == rewrittenMeta.status)
            #expect(sourceMeta.supersedes == rewrittenMeta.supersedes)
            #expect(sourceMeta.supersededBy == rewrittenMeta.supersededBy)
            #expect(sourceMeta.searchText == rewrittenMeta.searchText)
            #expect(sourceMeta.metadata == rewrittenMeta.metadata)

            let sourceContent = try await sourceWax.frameContent(frameId: sourceMeta.id)
            let rewrittenContent = try await rewrittenWax.frameContent(frameId: sourceMeta.id)
            if sourceMeta.status == .active && sourceMeta.supersededBy == nil {
                #expect(sourceContent == rewrittenContent)
            } else {
                #expect(rewrittenContent.isEmpty)
            }
        }

        try await sourceWax.close()
        try await rewrittenWax.close()

        let reopened = try await MemoryOrchestrator(at: destinationURL, config: config)
        let context = try await reopened.recall(query: "actors scheduling safety")
        #expect(!context.items.isEmpty)
        try await reopened.close()
    }
}

@Test
func rewriteLiveSetRespectsDestinationOverwriteGuard() async throws {
    try await TempFiles.withTempFile { sourceURL in
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mv2s")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: sourceURL, config: config)
        try await orchestrator.remember("single rewrite guard frame")
        try await orchestrator.flush()

        FileManager.default.createFile(atPath: destinationURL.path, contents: Data("occupied".utf8))
        await #expect(throws: WaxError.self) {
            _ = try await orchestrator.rewriteLiveSet(to: destinationURL)
        }

        let report = try await orchestrator.rewriteLiveSet(
            to: destinationURL,
            options: .init(overwriteDestination: true, dropNonLivePayloads: true, verifyDeep: false)
        )
        #expect(report.destinationURL == destinationURL.standardizedFileURL)
        try await orchestrator.close()
    }
}
