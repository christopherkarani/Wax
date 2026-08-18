#if canImport(ImageIO)
import Foundation

/// Public facade for on-device photo retrieval-augmented generation.
///
/// `PhotoMemory` is the supported public entry point over the package-scoped
/// `PhotoRAGOrchestrator`. It ingests Photos assets or local image files, extracts
/// metadata and OCR text, computes multimodal embeddings, and serves ranked photo
/// recall for natural-language queries.
///
/// The pipeline is experimental: the facade API is intentionally small, and the
/// underlying orchestrator remains package-scoped.
///
/// ```swift
/// let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
/// let photos = try await PhotoMemory(
///     at: storeURL,
///     embedder: embedder,
///     ocr: VisionOCRProvider()
/// )
/// try await photos.ingest(files: [PhotoFile(id: "receipt-1", url: imageURL)])
/// let context = try await photos.recall(PhotoQuery(text: "coffee receipt"))
/// try await photos.close()
/// ```
public actor PhotoMemory {
    private let orchestrator: PhotoRAGOrchestrator
    private var isClosed = false

    /// Create or open a photo memory store at the given URL.
    ///
    /// - Parameters:
    ///   - url: Store location on disk. Created if missing.
    ///   - config: Ingestion, OCR, region, search, and output tuning.
    ///   - embedder: Multimodal embedding provider shared by image and text lanes.
    ///   - ocr: Optional OCR provider (see ``VisionOCRProvider``).
    ///   - captioner: Optional caption provider for short image descriptions.
    public init(
        at url: URL,
        config: PhotoRAGConfig = .default,
        embedder: any MultimodalEmbeddingProvider,
        ocr: (any OCRProvider)? = nil,
        captioner: (any CaptionProvider)? = nil
    ) async throws {
        orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: embedder,
            ocr: ocr,
            captioner: captioner
        )
    }

    #if canImport(Photos)
    /// Sync photos from the Photos library into the store.
    ///
    /// Requires Photos authorization.
    public func syncLibrary(scope: PhotoScope) async throws {
        try await orchestrator.syncLibrary(scope: scope)
    }

    /// Ingest Photos-library assets by local identifier.
    ///
    /// Requires Photos authorization.
    public func ingest(assetIDs: [String]) async throws {
        try await orchestrator.ingest(assetIDs: assetIDs)
    }
    #endif

    /// Ingest local image files.
    public func ingest(files: [PhotoFile]) async throws {
        try await orchestrator.ingest(files: files)
    }

    /// Recall ranked photo context for a query.
    public func recall(_ query: PhotoQuery) async throws -> PhotoRAGContext {
        try await orchestrator.recall(query)
    }

    /// Delete a photo and all derived frames (OCR, caption, tags, regions) plus vectors.
    public func delete(assetID: String) async throws {
        try await orchestrator.delete(assetID: assetID)
    }

    /// Force pending writes to durable storage.
    public func flush() async throws {
        try await orchestrator.flush()
    }

    /// Flush pending writes and close the store. Safe to call more than once.
    public func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        try await orchestrator.close()
    }
}
#endif // canImport(ImageIO)
