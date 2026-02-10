import Foundation

/// Errors that can occur while ingesting a PDF.
public enum PDFIngestError: Error, Sendable, Equatable {
    case fileNotFound(url: URL)
    case loadFailed(url: URL)
    case noExtractableText(url: URL, pageCount: Int)
}

extension PDFIngestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(url):
            return "PDF file not found: \(url.path)"
        case let .loadFailed(url):
            return "PDF file could not be opened: \(url.path)"
        case let .noExtractableText(url, pageCount):
            return "PDF has no extractable text (pages: \(pageCount)): \(url.path)"
        }
    }
}
