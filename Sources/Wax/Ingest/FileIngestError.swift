import Foundation

/// Errors that can occur while ingesting a local text file.
public enum FileIngestError: Error, Sendable, Equatable {
    case fileNotFound(url: URL)
    case loadFailed(url: URL)
    case unsupportedTextEncoding(url: URL)
    case emptyContent(url: URL)
}

extension FileIngestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(url):
            return "File not found: \(url.path)"
        case let .loadFailed(url):
            return "File could not be read: \(url.path)"
        case let .unsupportedTextEncoding(url):
            return "File is not UTF-8 text: \(url.path)"
        case let .emptyContent(url):
            return "File has no text content: \(url.path)"
        }
    }
}
