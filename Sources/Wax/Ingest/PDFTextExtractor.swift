import Foundation

#if canImport(PDFKit)
import PDFKit

/// Extracts text from a PDF.
enum PDFTextExtractor {
    /// Extracts text from a PDF at the supplied URL.
    ///
    /// - Parameters:
    ///   - url: The file URL of the PDF.
    ///   - maxPages: Maximum number of pages to extract text from. If the PDF has more pages,
    ///     partial text is returned alongside the actual total page count.
    static func extractText(url: URL, maxPages: Int = 500) throws -> (text: String, pageCount: Int) {
        guard let document = PDFDocument(url: url) else {
            throw PDFIngestError.loadFailed(url: url)
        }

        let pageCount = document.pageCount
        let limit = min(pageCount, max(0, maxPages))
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

        return (combined, pageCount)
    }
}
#endif
