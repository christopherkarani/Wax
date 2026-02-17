import Foundation
import Testing
import Wax

private func makeFileIngestTextOnlyConfig() -> OrchestratorConfig {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.chunking = .tokenCount(targetTokens: 20, overlapTokens: 4)
    config.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .textOnly
    )
    return config
}

private func writeFixtureFile(contents: String, fileExtension: String = "txt") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-fixture-\(UUID().uuidString)")
        .appendingPathExtension(fileExtension)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test
func fileIngestRecallFindsExtractedText() async throws {
    let phrase = "laminar flow memory"
    let fileURL = try writeFixtureFile(contents: "Wax keeps \(phrase) deterministic.")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    try await TempFiles.withTempFile { storeURL in
        let orchestrator = try await MemoryOrchestrator(at: storeURL, config: makeFileIngestTextOnlyConfig())
        try await orchestrator.remember(fileAt: fileURL, metadata: ["source": "fixture"])

        let ctx = try await orchestrator.recall(query: phrase)
        #expect(!ctx.items.isEmpty)
        try await orchestrator.close()
    }
}

@Test
func fileIngestMetadataPropagatesToDocumentAndChunks() async throws {
    let content = "Wax file ingest metadata propagation test. " + String(repeating: "chunk ", count: 80)
    let fileURL = try writeFixtureFile(contents: content, fileExtension: "md")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    try await TempFiles.withTempFile { storeURL in
        let orchestrator = try await MemoryOrchestrator(at: storeURL, config: makeFileIngestTextOnlyConfig())
        try await orchestrator.remember(fileAt: fileURL, metadata: ["source": "fixture", "tag": "file"])
        try await orchestrator.close()

        let wax = try await Wax.open(at: storeURL)
        let stats = await wax.stats()
        #expect(stats.frameCount >= 2)

        let doc = try await wax.frameMeta(frameId: 0)
        #expect(doc.role == .document)
        #expect(doc.metadata?.entries["source"] == "fixture")
        #expect(doc.metadata?.entries["tag"] == "file")
        #expect(doc.metadata?.entries["source_kind"] == "file")
        #expect(doc.metadata?.entries["source_uri"] == fileURL.absoluteString)
        #expect(doc.metadata?.entries["source_filename"] == fileURL.lastPathComponent)
        #expect(doc.metadata?.entries["source_extension"] == "md")

        for frameId in UInt64(1)..<stats.frameCount {
            let meta = try await wax.frameMeta(frameId: frameId)
            #expect(meta.role == .chunk)
            #expect(meta.metadata?.entries["source"] == "fixture")
            #expect(meta.metadata?.entries["tag"] == "file")
            #expect(meta.metadata?.entries["source_kind"] == "file")
            #expect(meta.metadata?.entries["source_uri"] == fileURL.absoluteString)
            #expect(meta.metadata?.entries["source_filename"] == fileURL.lastPathComponent)
            #expect(meta.metadata?.entries["source_extension"] == "md")
        }

        try await wax.close()
    }
}

@Test
func fileIngestMissingFileThrowsFileNotFound() async throws {
    let missingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-missing-\(UUID().uuidString)")
        .appendingPathExtension("txt")

    try await TempFiles.withTempFile { storeURL in
        let orchestrator = try await MemoryOrchestrator(at: storeURL, config: makeFileIngestTextOnlyConfig())
        do {
            try await orchestrator.remember(fileAt: missingURL)
            Issue.record("Expected fileNotFound for missing file")
        } catch let error as FileIngestError {
            guard case let .fileNotFound(url) = error else {
                Issue.record("Expected .fileNotFound, got \(error)")
                return
            }
            #expect(url == missingURL)
        }
        try await orchestrator.close()
    }
}
