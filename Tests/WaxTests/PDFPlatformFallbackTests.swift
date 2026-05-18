import Foundation
import Testing
import Wax

@Test
func pdfIngestAPIHasNonPDFKitFallback() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let orchestratorSource = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Orchestrator/MemoryOrchestrator+PDF.swift"),
        encoding: .utf8
    )
    let errorSource = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Ingest/PDFIngestError.swift"),
        encoding: .utf8
    )

    #expect(orchestratorSource.contains("#else"))
    #expect(orchestratorSource.contains("func remember("))
    #expect(orchestratorSource.contains("pdfAt url: URL"))
    #expect(orchestratorSource.contains("metadata: [String: String] = [:]"))
    #expect(orchestratorSource.contains("PDFIngestError.unsupportedPlatform"))
    #expect(errorSource.contains("case unsupportedPlatform"))
}

#if !canImport(PDFKit)
@Test
func pdfIngestThrowsUnsupportedPlatformWhenPDFKitIsUnavailable() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-pdf-fallback-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }

    try await {
        let orchestrator = try await MemoryOrchestrator(at: url)
        let pdfURL = url.deletingLastPathComponent().appendingPathComponent("fixture.pdf")

        do {
            try await orchestrator.remember(pdfAt: pdfURL)
            Issue.record("Expected unsupportedPlatform when PDFKit is unavailable")
        } catch let error as PDFIngestError {
            guard case let .unsupportedPlatform(url) = error else {
                Issue.record("Expected .unsupportedPlatform, got \(error)")
                return
            }
            #expect(url == pdfURL)
        }

        try await orchestrator.close()
    }()
}
#endif
