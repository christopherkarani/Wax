import Foundation

#if canImport(PDFKit)
import PDFKit

/// Extracts text from a PDF.
enum PDFTextExtractor {
    /// Extracts text from a PDF at the supplied URL.
    static func extractText(url: URL) throws -> (text: String, pageCount: Int) {
        guard let document = PDFDocument(url: url) else {
            throw PDFIngestError.loadFailed(url: url)
        }

        let pageCount = document.pageCount
        var pageTexts: [String] = []
        pageTexts.reserveCapacity(pageCount)

        if pageCount > 0 {
            for index in 0..<pageCount {
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
