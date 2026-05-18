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

        var baseMetadata = metadata
        baseMetadata[PDFMetadataKeys.sourceKind] = "pdf"
        baseMetadata[PDFMetadataKeys.sourceURI] = url.absoluteString
        baseMetadata[PDFMetadataKeys.sourceFilename] = url.lastPathComponent
        baseMetadata[PDFMetadataKeys.pdfPageCount] = String(extracted.pageCount)
        baseMetadata[PDFMetadataKeys.pdfExtractedPageCount] = String(extracted.extractedPageCount)
        baseMetadata[PDFMetadataKeys.pdfMaxPages] = String(extracted.maxPages)
        baseMetadata[PDFMetadataKeys.pdfTruncated] = String(extracted.isTruncated)

        for page in extracted.pages {
            var pageMetadata = baseMetadata
            pageMetadata[PDFMetadataKeys.pdfPageNumber] = String(page.number)
            try await remember(page.text, metadata: pageMetadata)
        }
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
    static let pdfPageNumber = "pdf_page_number"
}
