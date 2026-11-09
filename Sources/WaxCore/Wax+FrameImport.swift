import Foundation

/// Frame import: many frames and embeddings written as one commit, outside the WAL.
///
/// An import writes each frame's payload straight to the data region and keeps its frame
/// record and embeddings in memory, so it never fills the WAL ring and never forces an
/// intermediate commit. ``Wax/commitFrameImport(memoryBinding:)`` publishes all of it in one
/// commit. Until then nothing of the import is in the TOC or the WAL: readers see the store
/// as it was, a crash recovers the previous commit, and the payload ranges are unreferenced
/// free space that the next open (or ``Wax/abandonFrameImport()``) hands back for reuse.
///
/// While an import is open, every other write (frame and embedding writes, removals,
/// deletes, supersedes, commits and close) waits for it to commit or be abandoned. Reads do
/// not wait.
extension Wax {
    /// What an open import has written so far.
    /// Internal only because of the file split.
    struct FrameImport {
        /// Frame ids continue the store's dense id sequence from here.
        var firstFrameId: UInt64
        var frames: [FrameMeta] = []
        var embeddings: [PutEmbedding] = []
        /// Data-region ranges holding the imported payloads.
        var payloadRanges: [Range<UInt64>] = []

        var nextFrameId: UInt64 { firstFrameId + UInt64(frames.count) }
    }

    /// Opens an import. Returns `false`, opening nothing, while WAL mutations or a text index
    /// are pending: an import starts from a committed store, so commit first and try again.
    package func beginFrameImport() async throws -> Bool {
        try await withMutationLock {
            guard pendingMutations.isEmpty, !hasStagedLexIndexLocked else { return false }
            frameImport = FrameImport(firstFrameId: UInt64(toc.frames.count))
            return true
        }
    }

    /// Writes the payloads of new frames for the open import and returns their ids, which
    /// continue after the store's frames and the frames imported before.
    package func importFrames(_ contents: [Data], options: [FrameMetaSubset]) async throws -> [UInt64] {
        guard contents.count == options.count else {
            throw WaxError.encodingError(reason: "importFrames: contents.count (\(contents.count)) != options.count (\(options.count))")
        }
        guard !contents.isEmpty else { return [] }
        return try await withWriteLock {
            guard var current = frameImport else { throw Self.noFrameImport }
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
            let totalBytes = contents.reduce(UInt64(0)) { $0 + UInt64($1.count) }
            let startOffset = allocateDataLocked(length: totalBytes)
            var offset = startOffset
            var frames: [FrameMeta] = []
            frames.reserveCapacity(contents.count)
            for (content, option) in zip(contents, options) {
                let checksum = SHA256Checksum.digest(content)
                frames.append(try FrameMeta.fromPut(PutFrame(
                    frameId: current.nextFrameId + UInt64(frames.count),
                    timestampMs: timestampMs,
                    options: option,
                    payloadOffset: offset,
                    payloadLength: UInt64(content.count),
                    canonicalEncoding: .plain,
                    canonicalLength: UInt64(content.count),
                    canonicalChecksum: checksum,
                    storedChecksum: checksum
                )))
                offset += UInt64(content.count)
            }
            if totalBytes > 0 {
                let file = self.file
                try await io.run {
                    var offset = startOffset
                    for content in contents {
                        try file.writeAll(content, at: offset)
                        offset += UInt64(content.count)
                    }
                }
                current.payloadRanges.append(startOffset..<(startOffset + totalBytes))
            }
            current.frames += frames
            dirty = true
            frameImport = current
            return frames.map(\.id)
        }
    }

    /// Adds embeddings for the open import: for its frames, or for frames the store already
    /// has. All of them must share one dimension, the store's if it has vectors.
    package func importEmbeddings(frameIds: [UInt64], vectors: [[Float]]) async throws {
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "importEmbeddings: frameIds.count != vectors.count")
        }
        guard !frameIds.isEmpty else { return }
        try await withWriteLock {
            guard var current = frameImport else { throw Self.noFrameImport }
            let expected = current.embeddings.first.map(\.dimension)
                ?? toc.indexes.vec?.dimension
                ?? vectorConfiguration?.dimension
            var dimension = expected
            for (frameId, vector) in zip(frameIds, vectors) {
                guard frameId < current.nextFrameId else {
                    throw WaxError.invalidToc(reason: "importEmbeddings references unknown frameId \(frameId) (known < \(current.nextFrameId))")
                }
                guard !vector.isEmpty else {
                    throw WaxError.encodingError(reason: "embedding vector must be non-empty")
                }
                guard vector.count <= Constants.maxEmbeddingDimensions else {
                    throw WaxError.capacityExceeded(
                        limit: UInt64(Constants.maxEmbeddingDimensions),
                        requested: UInt64(vector.count)
                    )
                }
                let vectorDimension = UInt32(vector.count)
                if let dimension, dimension != vectorDimension {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch in import: expected \(dimension), got \(vectorDimension)"
                    )
                }
                dimension = vectorDimension
                current.embeddings.append(PutEmbedding(frameId: frameId, dimension: vectorDimension, vector: vector))
            }
            frameImport = current
        }
    }

    /// Publishes the open import in one commit with whatever text index and vector
    /// configuration were staged for it, and sets `memoryBinding` if the store has none.
    /// Returns the embeddings it committed, for in-memory vector indexes.
    /// On a throw the store and the import are as they were: abandon the import or retry.
    @discardableResult
    package func commitFrameImport(memoryBinding: MemoryBinding? = nil) async throws -> [PutEmbedding] {
        try await withWriteLock {
            guard let current = frameImport else { throw Self.noFrameImport }
            let bindingBefore = toc.memoryBinding
            if let memoryBinding, !memoryBinding.isEmpty, bindingBefore == nil {
                toc.memoryBinding = memoryBinding
            }
            do {
                try await commitLocked(frameImport: current)
            } catch {
                toc.memoryBinding = bindingBefore
                throw error
            }
            endFrameImportLocked()
            return current.embeddings
        }
    }

    /// Drops the open import, if any, and the text index staged for it. Its payload ranges
    /// become free space again.
    package func abandonFrameImport() async {
        await withWriteLock {
            guard let current = frameImport else { return }
            for range in current.payloadRanges {
                dataSpace.free.release(range)
            }
            discardStagedLexIndexLocked()
            endFrameImportLocked()
        }
    }

    /// Whether an import is open.
    package func hasOpenFrameImport() async -> Bool {
        await withReadLock { frameImport != nil }
    }

    /// Writes parked until the open import ends. Tests only.
    package func frameImportWaiterCountForTesting() -> Int {
        frameImportEndWaiters.count
    }

    private static var noFrameImport: WaxError {
        WaxError.io("no frame import is open; call beginFrameImport() first")
    }

    private func endFrameImportLocked() {
        frameImport = nil
        let waiters = frameImportEndWaiters
        frameImportEndWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Internal only because of the file split.
    func waitUntilNoFrameImport() async {
        while frameImport != nil {
            await withCheckedContinuation { continuation in
                frameImportEndWaiters.append(continuation)
            }
        }
    }
}
