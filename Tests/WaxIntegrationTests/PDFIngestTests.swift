#if canImport(PDFKit)
import Foundation
import PDFKit
import Testing
import Wax

private struct PDFIngestTestingError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

private enum PDFFixtures {
    static let pageOnePhrase = "crimson"
    static let pageTwoPhrase = "cobalt"

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static var textPDF: URL {
        directory.appendingPathComponent("pdf_fixture_text.pdf")
    }

    static var blankPDF: URL {
        directory.appendingPathComponent("pdf_fixture_blank.pdf")
    }
}

private func makeTextOnlyConfig() -> OrchestratorConfig {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.chunking = .tokenCount(targetTokens: 24, overlapTokens: 4)
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

@Test
func pdfIngestRecallFindsExtractedText() async throws {
    #expect(FileManager.default.fileExists(atPath: PDFFixtures.textPDF.path))

    try await TempFiles.withTempFile { url in
        let orchestrator = try await MemoryOrchestrator(at: url, config: makeTextOnlyConfig())
        try await orchestrator.remember(pdfAt: PDFFixtures.textPDF, metadata: ["source": "fixture"])

        let ctxOne = try await orchestrator.recall(query: PDFFixtures.pageOnePhrase)
        #expect(!ctxOne.items.isEmpty)

        let ctxTwo = try await orchestrator.recall(query: PDFFixtures.pageTwoPhrase)
        #expect(!ctxTwo.items.isEmpty)

        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let docPayload = try await wax.frameContent(frameId: 0)
        let docText = String(decoding: docPayload, as: UTF8.self)
        #expect(docText.localizedCaseInsensitiveContains(PDFFixtures.pageOnePhrase))
        #expect(docText.localizedCaseInsensitiveContains(PDFFixtures.pageTwoPhrase))
        try await wax.close()
    }
}

@Test
func pdfIngestMetadataPropagatesToDocumentAndChunks() async throws {
    #expect(FileManager.default.fileExists(atPath: PDFFixtures.textPDF.path))

    try await TempFiles.withTempFile { url in
        let orchestrator = try await MemoryOrchestrator(at: url, config: makeTextOnlyConfig())
        try await orchestrator.remember(
            pdfAt: PDFFixtures.textPDF,
            metadata: ["source": "fixture", "tag": "pdf"]
        )
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount >= 2)

        let doc = try await wax.frameMeta(frameId: 0)
        #expect(doc.role == .document)
        #expect(doc.metadata?.entries["source"] == "fixture")
        #expect(doc.metadata?.entries["tag"] == "pdf")
        #expect(doc.metadata?.entries["source_kind"] == "pdf")
        #expect(doc.metadata?.entries["source_uri"] == PDFFixtures.textPDF.absoluteString)
        #expect(doc.metadata?.entries["source_filename"] == PDFFixtures.textPDF.lastPathComponent)
        #expect(doc.metadata?.entries["pdf_page_count"] == "2")

        for frameId in UInt64(1)..<stats.frameCount {
            let meta = try await wax.frameMeta(frameId: frameId)
            #expect(meta.role == .chunk)
            #expect(meta.metadata?.entries["source"] == "fixture")
            #expect(meta.metadata?.entries["tag"] == "pdf")
            #expect(meta.metadata?.entries["source_kind"] == "pdf")
            #expect(meta.metadata?.entries["source_uri"] == PDFFixtures.textPDF.absoluteString)
            #expect(meta.metadata?.entries["source_filename"] == PDFFixtures.textPDF.lastPathComponent)
            #expect(meta.metadata?.entries["pdf_page_count"] == "2")
        }

        try await wax.close()
    }
}

@Test
func pdfIngestBlankPDFThrowsNoExtractableText() async throws {
    #expect(FileManager.default.fileExists(atPath: PDFFixtures.blankPDF.path))

    try await TempFiles.withTempFile { url in
        let orchestrator = try await MemoryOrchestrator(at: url, config: makeTextOnlyConfig())
        do {
            try await orchestrator.remember(pdfAt: PDFFixtures.blankPDF)
            throw PDFIngestTestingError("Expected noExtractableText for blank PDF.")
        } catch let error as PDFIngestError {
            switch error {
            case let .noExtractableText(url, pageCount):
                #expect(url == PDFFixtures.blankPDF)
                #expect(pageCount >= 1)
            default:
                throw PDFIngestTestingError("Unexpected PDFIngestError: \(error)")
            }
        }
        try await orchestrator.close()
    }
}

@Test
func pdfIngestMissingFileThrowsFileNotFound() async throws {
    let missingURL = PDFFixtures.directory.appendingPathComponent("pdf_fixture_missing.pdf")
    if FileManager.default.fileExists(atPath: missingURL.path) {
        try FileManager.default.removeItem(at: missingURL)
    }

    try await TempFiles.withTempFile { url in
        let orchestrator = try await MemoryOrchestrator(at: url, config: makeTextOnlyConfig())
        do {
            try await orchestrator.remember(pdfAt: missingURL)
            throw PDFIngestTestingError("Expected fileNotFound for missing PDF.")
        } catch let error as PDFIngestError {
            switch error {
            case let .fileNotFound(url):
                #expect(url == missingURL)
            default:
                throw PDFIngestTestingError("Unexpected PDFIngestError: \(error)")
            }
        }
        try await orchestrator.close()
    }
}
#endif
