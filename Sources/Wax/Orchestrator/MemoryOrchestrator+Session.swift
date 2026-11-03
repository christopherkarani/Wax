import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    /// Internal only because of the file split.
    struct SessionRuntimeStatsCacheEntry: Sendable, Equatable {
        var generation: UInt64
        var frameIds: [UInt64]
        var tokenEstimate: Int
    }

    // MARK: - Session tagging (v1)

    package func startSession() -> UUID {
        let id = UUID()
        currentSessionId = id
        return id
    }

    package func endSession() {
        currentSessionId = nil
    }

    package func activeSessionId() -> UUID? {
        currentSessionId
    }

    package func sessionRuntimeStats() async throws -> SessionRuntimeStats {
        try await sessionRuntimeStats(sessionId: currentSessionId)
    }

    package func sessionRuntimeStats(sessionId: UUID?) async throws -> SessionRuntimeStats {
        let storeStats = await wax.stats()
        let pendingFramesStoreWide = storeStats.pendingFrames
        guard let sessionId else {
            return SessionRuntimeStats(
                active: false,
                sessionId: nil,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        let frameIds = await wax.activeFrameIDs(
            matchingMetadataKey: "session_id",
            value: sessionId.uuidString
        )

        guard !frameIds.isEmpty else {
            sessionRuntimeStatsCache[sessionId] = nil
            return SessionRuntimeStats(
                active: true,
                sessionId: sessionId,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        if let cached = sessionRuntimeStatsCache[sessionId],
           cached.generation == storeStats.generation,
           cached.frameIds == frameIds {
            return SessionRuntimeStats(
                active: true,
                sessionId: sessionId,
                sessionFrameCount: frameIds.count,
                sessionTokenEstimate: cached.tokenEstimate,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        let frameMetas = await wax.frameMetas(frameIds: frameIds)
        var textsByFrameID: [UInt64: String] = [:]
        textsByFrameID.reserveCapacity(frameIds.count)
        var missingSearchTextFrameIDs: [UInt64] = []
        missingSearchTextFrameIDs.reserveCapacity(frameIds.count)

        for frameId in frameIds {
            if let searchText = frameMetas[frameId]?.searchText {
                textsByFrameID[frameId] = searchText
            } else {
                missingSearchTextFrameIDs.append(frameId)
            }
        }

        if !missingSearchTextFrameIDs.isEmpty {
            let contentMap = try await wax.frameContents(frameIds: missingSearchTextFrameIDs)
            for frameId in missingSearchTextFrameIDs {
                guard let data = contentMap[frameId],
                      let text = String(data: data, encoding: .utf8) else {
                    continue
                }
                textsByFrameID[frameId] = text
            }
        }

        let texts = frameIds.compactMap { textsByFrameID[$0] }
        let tokenCounter = try await TokenCounter.shared()
        let tokenCounts = await tokenCounter.countBatch(texts)
        let totalTokens = tokenCounts.reduce(0, +)
        sessionRuntimeStatsCache[sessionId] = SessionRuntimeStatsCacheEntry(
            generation: storeStats.generation,
            frameIds: frameIds,
            tokenEstimate: totalTokens
        )

        return SessionRuntimeStats(
            active: true,
            sessionId: sessionId,
            sessionFrameCount: frameIds.count,
            sessionTokenEstimate: totalTokens,
            pendingFramesStoreWide: pendingFramesStoreWide,
            countsIncludePending: false
        )
    }
}
