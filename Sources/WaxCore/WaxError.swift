import Foundation

/// Errors that can occur during Wax operations
public enum WaxError: Error, LocalizedError, Sendable {
    case invalidHeader(reason: String)
    case invalidFooter(reason: String)
    case invalidToc(reason: String)
    case encodingError(reason: String)
    case decodingError(reason: String)
    case walCorruption(offset: UInt64, reason: String)
    case checksumMismatch(String)
    case lockUnavailable(String)
    case capacityExceeded(limit: UInt64, requested: UInt64)
    case frameNotFound(frameId: UInt64)
    case io(String)
    case writerBusy
    case writerTimeout
    /// An API was called that requires a feature disabled in the store configuration
    /// (for example text search, vector search, or structured memory).
    case featureDisabled(feature: String)
    /// An embedding provider returned a vector that failed validation
    /// (wrong dimensions, non-finite values, or zero magnitude).
    case invalidEmbedding(reason: String)
    /// Vector search is enabled but no embedding provider is configured.
    case missingEmbedder
    /// A commit was attempted with pending embeddings but no staged vector index.
    case vectorIndexNotStaged
    /// A commit was attempted after an embedding was written past the staged vector index.
    case vectorIndexStale
    /// Vector-only search was requested while the store's vectors, written by a superseded
    /// revision of the embedding model, are being re-embedded. `progress` is the fraction
    /// (0...1) of the store already re-embedded. Text and hybrid search keep working.
    case vectorsRebuilding(reason: String, progress: Double)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader(let reason):
            return "Invalid header: \(reason)"
        case .invalidFooter(let reason):
            return "Invalid footer: \(reason)"
        case .invalidToc(let reason):
            return "Invalid TOC: \(reason)"
        case .encodingError(let reason):
            return "Encoding error: \(reason)"
        case .decodingError(let reason):
            return "Decoding error: \(reason)"
        case .walCorruption(let offset, let reason):
            return "WAL corruption at offset \(offset): \(reason)"
        case .checksumMismatch(let details):
            return "Checksum mismatch: \(details)"
        case .lockUnavailable(let details):
            return "Lock unavailable: \(details)"
        case .capacityExceeded(let limit, let requested):
            return "Capacity exceeded: limit=\(limit), requested=\(requested)"
        case .frameNotFound(let frameId):
            return "Frame not found: \(frameId)"
        case .io(let details):
            return "I/O error: \(details)"
        case .writerBusy:
            return "Writer session already active"
        case .writerTimeout:
            return "Timed out waiting for writer session"
        case .featureDisabled(let feature):
            return "Feature disabled: \(feature). Enable it in the store configuration to use this API."
        case .invalidEmbedding(let reason):
            return "Invalid embedding: \(reason)"
        case .missingEmbedder:
            return "Vector search requires an embedding provider; set Memory.Config.embedding or disable vector search."
        case .vectorIndexNotStaged:
            return "vector index must be staged before committing embeddings"
        case .vectorIndexStale:
            return "vector index is stale relative to pending embeddings; restage vector index before commit"
        case .vectorsRebuilding(let reason, let progress):
            let percent = Int((min(max(progress, 0), 1) * 100).rounded(.down))
            return "Vector search is unavailable until stored vectors are re-embedded (\(reason); \(percent)% done). "
                + "Text and hybrid search use the text lane meanwhile; keep the store open to finish, "
                + "or run `wax-cli embed-backfill --direct-store` on a copy."
        }
    }
}
