import Foundation
import WaxCore

extension MemoryOrchestrator {
    /// Upper bound on the WAL bytes of one put beyond its search text and metadata strings:
    /// record header, fixed `PutFrame` fields, checksums, optional-field tags and the
    /// `wax.embedding.*` identity keys `putBatch(identity:)` adds.
    private static let walPutOverheadBytes: UInt64 = 512
    /// Upper bound on the WAL bytes of one embedding beyond its float components.
    private static let walEmbeddingOverheadBytes: UInt64 = 64

    /// Estimated WAL bytes for putting frames with these search texts and metadata, each
    /// with an embedding of `embeddingDimensions` floats when it is non-nil. Over-estimates.
    static func estimatedWalBytes(
        searchTexts: [String?],
        metadata: [String: String],
        embeddingDimensions: Int?
    ) -> UInt64 {
        let metadataBytes = metadata.reduce(UInt64(0)) { total, entry in
            total + UInt64(entry.key.utf8.count + entry.value.utf8.count)
        }
        let embeddingBytes = embeddingDimensions.map {
            walEmbeddingOverheadBytes + UInt64($0) * UInt64(MemoryLayout<Float>.size)
        } ?? 0
        return searchTexts.reduce(UInt64(0)) { total, text in
            total + walPutOverheadBytes + metadataBytes + UInt64(text?.utf8.count ?? 0) + embeddingBytes
        }
    }

    /// Stages the text and vector indexes and commits when `incomingBytes` more WAL bytes
    /// would fill more than half of the WAL.
    ///
    /// The store cannot auto-commit a full WAL while embeddings are pending, because only the
    /// session can stage the vector index that covers them, so saves that never `flush()`
    /// would otherwise fail with a WAL-capacity error. Committing at half capacity leaves
    /// the other half for writes that interleave with this one.
    func commitIfWalPressure(incomingBytes: UInt64) async throws {
        guard await walPressureRequiresCommit(incomingBytes: incomingBytes) else { return }
        try await flushMutex.withLock { [self] in
            // A flush or another save may have committed while this one waited.
            guard await self.walPressureRequiresCommit(incomingBytes: incomingBytes) else { return }
            try await self.session.commit()
        }
    }

    private func walPressureRequiresCommit(incomingBytes: UInt64) async -> Bool {
        let wal = await wax.walStats()
        guard wal.pendingBytes > 0 else { return false }
        let (projected, overflowed) = wal.pendingBytes.addingReportingOverflow(incomingBytes)
        return overflowed || projected > wal.walSize / 2
    }
}
