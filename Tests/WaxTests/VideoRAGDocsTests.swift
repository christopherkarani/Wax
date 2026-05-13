import Foundation
import Testing

@Test
func videoRAGDocsDoNotAdvertisePackageOnlyOrchestratorAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package actor VideoRAGOrchestrator"))
    #expect(source.contains("package init("))

    for relativePath in videoRAGDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("package-only"))
        #expect(doc.contains("not public API"))
        #expect(!doc.contains("VideoRAGOrchestrator provides"))
        #expect(!doc.contains("let orchestrator = try await VideoRAGOrchestrator("))
        #expect(!doc.contains("try await orchestrator.ingest"))
        #expect(!doc.contains("try await orchestrator.syncLibrary"))
    }
}

private let videoRAGDocPaths = [
    "Sources/Wax/Wax.docc/Articles/VideoRAG.md",
    "Resources/website/docs/media/video-rag.md",
]
