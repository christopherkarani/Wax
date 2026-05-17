#if canImport(PDFKit)
import Foundation
import CoreText
import PDFKit
import Testing
import Wax

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

private func writeBlankThenTextPDF(to url: URL, text: String) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 300)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    context.beginPDFPage(nil)
    context.endPDFPage()

    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let attributed = NSAttributedString(
        string: text,
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: 36, y: 140)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
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
        let stats = await wax.stats()
        var storedText = ""
        for frameId in UInt64(0)..<stats.frameCount {
            let payload = try await wax.frameContent(frameId: frameId)
            storedText += "\n" + String(decoding: payload, as: UTF8.self)
        }
        #expect(storedText.localizedCaseInsensitiveContains(PDFFixtures.pageOnePhrase))
        #expect(storedText.localizedCaseInsensitiveContains(PDFFixtures.pageTwoPhrase))
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

        var documentCount = 0
        var chunkCount = 0
        for frameId in UInt64(0)..<stats.frameCount {
            let meta = try await wax.frameMeta(frameId: frameId)
            if meta.role == .document {
                documentCount += 1
            } else if meta.role == .chunk {
                chunkCount += 1
            }
            #expect(meta.metadata?.entries["source"] == "fixture")
            #expect(meta.metadata?.entries["tag"] == "pdf")
            #expect(meta.metadata?.entries["source_kind"] == "pdf")
            #expect(meta.metadata?.entries["source_uri"] == PDFFixtures.textPDF.absoluteString)
            #expect(meta.metadata?.entries["source_filename"] == PDFFixtures.textPDF.lastPathComponent)
            #expect(meta.metadata?.entries["pdf_page_count"] == "2")
        }
        #expect(documentCount == 2)
        #expect(chunkCount >= 2)

        try await wax.close()
    }
}

@Test
func pdfIngestTruncationMetadataRecordsExtractedPageCoverage() async throws {
    #expect(FileManager.default.fileExists(atPath: PDFFixtures.textPDF.path))

    try await TempFiles.withTempFile { url in
        let orchestrator = try await MemoryOrchestrator(at: url, config: makeTextOnlyConfig())
        try await orchestrator.remember(
            pdfAt: PDFFixtures.textPDF,
            maxPages: 1,
            metadata: ["source": "fixture"]
        )
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let doc = try await wax.frameMeta(frameId: 0)
        #expect(doc.metadata?.entries["pdf_page_count"] == "2")
        #expect(doc.metadata?.entries["pdf_extracted_page_count"] == "1")
        #expect(doc.metadata?.entries["pdf_max_pages"] == "1")
        #expect(doc.metadata?.entries["pdf_truncated"] == "true")

        let docPayload = try await wax.frameContent(frameId: 0)
        let docText = String(decoding: docPayload, as: UTF8.self)
        #expect(docText.localizedCaseInsensitiveContains(PDFFixtures.pageOnePhrase))
        #expect(!docText.localizedCaseInsensitiveContains(PDFFixtures.pageTwoPhrase))
        try await wax.close()
    }
}

@Test
func pdfIngestCountsBlankPagesWithinExtractionCoverage() async throws {
    try await TempFiles.withTempFile(fileExtension: "wax") { url in
        let pdfURL = url.deletingLastPathComponent()
            .appendingPathComponent("blank-then-text-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        try writeBlankThenTextPDF(to: pdfURL, text: "second page provenance marker")

        let orchestrator = try await MemoryOrchestrator(at: url, config: makeTextOnlyConfig())
        try await orchestrator.remember(pdfAt: pdfURL, maxPages: 2)
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount >= 1)
        let meta = try await wax.frameMeta(frameId: 0)
        #expect(meta.metadata?.entries["pdf_page_count"] == "2")
        #expect(meta.metadata?.entries["pdf_extracted_page_count"] == "2")
        #expect(meta.metadata?.entries["pdf_page_number"] == "2")
        try await wax.close()
    }
}

@Test
func pdfIngestStoresPageProvenanceInFrameMetadata() async throws {
    #expect(FileManager.default.fileExists(atPath: PDFFixtures.textPDF.path))

    try await TempFiles.withTempFile { url in
        let orchestrator = try await MemoryOrchestrator(at: url, config: makeTextOnlyConfig())
        try await orchestrator.remember(pdfAt: PDFFixtures.textPDF, metadata: ["source": "fixture"])
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()

        var pageOneFrames = 0
        var pageTwoFrames = 0
        for frameId in UInt64(0)..<stats.frameCount {
            let meta = try await wax.frameMeta(frameId: frameId)
            let payload = try await wax.frameContent(frameId: frameId)
            let text = String(decoding: payload, as: UTF8.self)

            switch meta.metadata?.entries["pdf_page_number"] {
            case "1":
                pageOneFrames += 1
                #expect(text.localizedCaseInsensitiveContains(PDFFixtures.pageOnePhrase))
                #expect(!text.localizedCaseInsensitiveContains(PDFFixtures.pageTwoPhrase))
            case "2":
                pageTwoFrames += 1
                #expect(text.localizedCaseInsensitiveContains(PDFFixtures.pageTwoPhrase))
                #expect(!text.localizedCaseInsensitiveContains(PDFFixtures.pageOnePhrase))
            default:
                break
            }
        }

        #expect(pageOneFrames >= 1)
        #expect(pageTwoFrames >= 1)
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
            Issue.record("Expected noExtractableText for blank PDF")
        } catch let error as PDFIngestError {
            guard case let .noExtractableText(url, pageCount) = error else {
                Issue.record("Expected .noExtractableText, got \(error)")
                return
            }
            #expect(url == PDFFixtures.blankPDF)
            #expect(pageCount >= 1)
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
            Issue.record("Expected fileNotFound for missing PDF")
        } catch let error as PDFIngestError {
            guard case let .fileNotFound(url) = error else {
                Issue.record("Expected .fileNotFound, got \(error)")
                return
            }
            #expect(url == missingURL)
        }
        try await orchestrator.close()
    }
}
#endif
