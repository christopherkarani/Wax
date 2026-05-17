import Foundation

package extension MemoryOrchestrator {
    /// Extracts text from a PDF and ingests it as document + chunks.
    func remember(
        pdfAt url: URL,
        maxPages: Int = 500,
        metadata: [String: String] = [:]
    ) async throws {
        #if canImport(PDFKit)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw PDFIngestError.fileNotFound(url: url)
        }

        let extracted = try await Task.detached(priority: .utility) {
            try PDFTextExtractor.extractText(url: url, maxPages: maxPages)
        }.value

        var mergedMetadata = metadata
        mergedMetadata[PDFMetadataKeys.sourceKind] = "pdf"
        mergedMetadata[PDFMetadataKeys.sourceURI] = url.absoluteString
        mergedMetadata[PDFMetadataKeys.sourceFilename] = url.lastPathComponent
        mergedMetadata[PDFMetadataKeys.pdfPageCount] = String(extracted.pageCount)
        mergedMetadata[PDFMetadataKeys.pdfExtractedPageCount] = String(extracted.extractedPageCount)
        mergedMetadata[PDFMetadataKeys.pdfMaxPages] = String(extracted.maxPages)
        mergedMetadata[PDFMetadataKeys.pdfTruncated] = String(extracted.isTruncated)

        try await remember(extracted.text, metadata: mergedMetadata)
        #else
        _ = maxPages
        _ = metadata
        throw PDFIngestError.unsupportedPlatform(url: url)
        #endif
    }
}

private enum PDFMetadataKeys {
    static let sourceKind = "source_kind"
    static let sourceURI = "source_uri"
    static let sourceFilename = "source_filename"
    static let pdfPageCount = "pdf_page_count"
    static let pdfExtractedPageCount = "pdf_extracted_page_count"
    static let pdfMaxPages = "pdf_max_pages"
    static let pdfTruncated = "pdf_truncated"
}
