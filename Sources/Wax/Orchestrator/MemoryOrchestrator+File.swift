import Foundation

public extension MemoryOrchestrator {
    /// Extracts UTF-8 text from a local file and ingests it as document + chunks.
    func remember(fileAt url: URL, metadata: [String: String] = [:]) async throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw FileIngestError.fileNotFound(url: url)
        }

        let data = try await Task.detached(priority: .utility) {
            do {
                return try Data(contentsOf: url)
            } catch {
                throw FileIngestError.loadFailed(url: url)
            }
        }.value

        guard let text = String(data: data, encoding: .utf8) else {
            throw FileIngestError.unsupportedTextEncoding(url: url)
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileIngestError.emptyContent(url: url)
        }

        var mergedMetadata = metadata
        mergedMetadata[FileMetadataKeys.sourceKind] = "file"
        mergedMetadata[FileMetadataKeys.sourceURI] = url.absoluteString
        mergedMetadata[FileMetadataKeys.sourceFilename] = url.lastPathComponent
        if !url.pathExtension.isEmpty {
            mergedMetadata[FileMetadataKeys.sourceExtension] = url.pathExtension.lowercased()
        }

        try await remember(text, metadata: mergedMetadata)
    }
}

private enum FileMetadataKeys {
    static let sourceKind = "source_kind"
    static let sourceURI = "source_uri"
    static let sourceFilename = "source_filename"
    static let sourceExtension = "source_extension"
}
