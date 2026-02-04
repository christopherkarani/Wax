import Foundation

#if canImport(PDFKit)
public extension MemoryOrchestrator {
    /// Extracts text from a PDF and ingests it as document + chunks.
    func remember(pdfAt url: URL, metadata: [String: String] = [:]) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFIngestError.fileNotFound(url: url)
        }

        let extracted = try await withThrowingTaskGroup(of: (text: String, pageCount: Int).self) { group in
            group.addTask(priority: .utility) {
                try PDFTextExtractor.extractText(url: url)
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }

            return result
        }

        var mergedMetadata = metadata
        mergedMetadata[PDFMetadataKeys.sourceKind] = "pdf"
        mergedMetadata[PDFMetadataKeys.sourceURI] = url.absoluteString
        mergedMetadata[PDFMetadataKeys.sourceFilename] = url.lastPathComponent
        mergedMetadata[PDFMetadataKeys.pdfPageCount] = String(extracted.pageCount)

        try await remember(extracted.text, metadata: mergedMetadata)
    }
}

private enum PDFMetadataKeys {
    static let sourceKind = "source_kind"
    static let sourceURI = "source_uri"
    static let sourceFilename = "source_filename"
    static let pdfPageCount = "pdf_page_count"
}
#endif
