import Foundation

#if canImport(PDFKit)
import PDFKit

/// Extracts text from a PDF.
enum PDFTextExtractor {
    struct Extraction: Sendable, Equatable {
        let text: String
        let pageCount: Int
        let extractedPageCount: Int
        let maxPages: Int
        let isTruncated: Bool
    }

    /// Extracts text from a PDF at the supplied URL.
    ///
    /// - Parameters:
    ///   - url: The file URL of the PDF.
    ///   - maxPages: Maximum number of pages to extract text from. If the PDF has more pages,
    ///     partial text is returned alongside the actual total page count.
    static func extractText(url: URL, maxPages: Int = 500) throws -> Extraction {
        guard let document = PDFDocument(url: url) else {
            throw PDFIngestError.loadFailed(url: url)
        }

        let pageCount = document.pageCount
        let normalizedMaxPages = max(0, maxPages)
        let limit = min(pageCount, normalizedMaxPages)
        var pageTexts: [String] = []
        pageTexts.reserveCapacity(limit)

        if limit > 0 {
            for index in 0..<limit {
                guard let page = document.page(at: index) else { continue }
                guard let text = page.string, !text.isEmpty else { continue }
                pageTexts.append(text)
            }
        }

        let combined = pageTexts
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !combined.isEmpty else {
            throw PDFIngestError.noExtractableText(url: url, pageCount: pageCount)
        }

        return Extraction(
            text: combined,
            pageCount: pageCount,
            extractedPageCount: limit,
            maxPages: normalizedMaxPages,
            isTruncated: limit < pageCount
        )
    }
}
#endif
