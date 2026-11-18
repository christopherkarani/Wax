import Foundation
import WaxCore

/// Progress markers for the superseded-model re-embed in `MemoryOrchestrator.swift`.
extension MemoryOrchestrator {
    /// Writes the new marker and commits it with every vector re-embedded so far.
    /// Internal only because of the file split.
    func checkpointSupersededReembed(
        nextFrameId: UInt64,
        targetModel: String,
        previousMarkerFrameId: UInt64?
    ) async throws -> UInt64 {
        try await embeddingBackfillStoreMutex.withLock { [self] in
            try Task.checkCancellation()
            guard !(await isClosed) else { throw CancellationError() }
            let markerFrameId = try await putSupersededReembedMarker(
                nextFrameId: nextFrameId,
                targetModel: targetModel,
                previousMarkerFrameId: previousMarkerFrameId
            )
            try await flush()
            return markerFrameId
        }
    }

    /// Final checkpoint for a run that stopped early. The marker only claims frames whose new
    /// vectors are already in the WAL, and lands in the same commit as any still pending.
    /// After `close` starts, `close` writes it instead, inside its own final flush.
    /// Internal only because of the file split.
    func checkpointInterruptedSupersededReembed() async {
        do {
            try await embeddingBackfillStoreMutex.withLock { [self] in
                guard !(await isClosed) else { return }
                if try await putUncheckpointedSupersededReembedMarker() {
                    try await flush()
                }
            }
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "superseded re-embed interruption checkpoint",
                fallback: "resume redoes frames since the last committed checkpoint"
            )
        }
    }

    /// Callers hold `embeddingBackfillStoreMutex` and commit afterwards.
    /// Internal only because of the file split.
    func putUncheckpointedSupersededReembedMarker() async throws -> Bool {
        guard let progress = uncheckpointedSupersededReembed else { return false }
        _ = try await putSupersededReembedMarker(
            nextFrameId: progress.nextFrameId,
            targetModel: progress.targetModel,
            previousMarkerFrameId: progress.markerFrameId
        )
        uncheckpointedSupersededReembed = nil
        return true
    }

    /// Callers hold `embeddingBackfillStoreMutex` and commit afterwards.
    private func putSupersededReembedMarker(
        nextFrameId: UInt64,
        targetModel: String,
        previousMarkerFrameId: UInt64?
    ) async throws -> UInt64 {
        var metadata = Metadata()
        metadata.entries[Self.reembedTargetModelKey] = targetModel
        metadata.entries[Self.reembedNextFrameIdKey] = String(nextFrameId)
        let markerFrameId = try await session.put(
            Data(),
            options: FrameMetaSubset(
                kind: Self.reembedProgressFrameKind,
                labels: [Self.accessStatsLabel],
                role: .system,
                metadata: metadata
            )
        )
        if let previousMarkerFrameId {
            try await wax.delete(frameId: previousMarkerFrameId)
        }
        return markerFrameId
    }
}
