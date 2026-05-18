import Foundation

#if canImport(PDFKit)
import PDFKit

/// Extracts text from a PDF.
enum PDFTextExtractor {
    struct Page: Sendable, Equatable {
        let number: Int
        let text: String
    }

    struct Extraction: Sendable, Equatable {
        let text: String
        let pageCount: Int
        let extractedPageCount: Int
        let maxPages: Int
        let isTruncated: Bool
        let pages: [Page]
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
        var pages: [Page] = []
        pages.reserveCapacity(limit)

        if limit > 0 {
            for index in 0..<limit {
                guard let page = document.page(at: index) else { continue }
                guard let text = page.string else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                pages.append(Page(number: index + 1, text: trimmed))
            }
        }

        let combined = pages
            .map(\.text)
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
            isTruncated: limit < pageCount,
            pages: pages
        )
    }
}
#endif
