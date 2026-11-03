import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    package struct RememberResult: Sendable, Equatable {
        package var frameId: UInt64
        package var framesAdded: UInt64
        package var deduplicated: Bool
        package var searchable: Bool

        package init(
            frameId: UInt64,
            framesAdded: UInt64,
            deduplicated: Bool,
            searchable: Bool
        ) {
            self.frameId = frameId
            self.framesAdded = framesAdded
            self.deduplicated = deduplicated
            self.searchable = searchable
        }
    }

    /// Stable search hit DTO for MCP and other raw-search callers.
    package struct MemorySearchHit: Sendable, Equatable {
        package var frameId: UInt64
        package var score: Float
        package var previewText: String?
        package var sources: [SearchResponse.Source]
        package var metadata: [String: String]
        package var explanations: [String]

        package init(
            frameId: UInt64,
            score: Float,
            previewText: String?,
            sources: [SearchResponse.Source],
            metadata: [String: String] = [:],
            explanations: [String] = []
        ) {
            self.frameId = frameId
            self.score = score
            self.previewText = previewText
            self.sources = sources
            self.metadata = metadata
            self.explanations = explanations
        }
    }

    package struct SearchExecution: Sendable, Equatable {
        package var hits: [MemorySearchHit]
        package var diagnostics: RAGContext.Diagnostics

        package var requestedMode: SearchMode { diagnostics.requestedMode }
        package var effectiveMode: SearchMode { diagnostics.effectiveMode }
        package var queryEmbeddingState: RAGContext.QueryEmbeddingState {
            diagnostics.queryEmbeddingState
        }

        package init(hits: [MemorySearchHit], diagnostics: RAGContext.Diagnostics) {
            self.hits = hits
            self.diagnostics = diagnostics
        }
    }

    package struct RecallExecution: Sendable, Equatable {
        package var context: RAGContext
        package var diagnostics: RAGContext.Diagnostics

        package var requestedMode: SearchMode { diagnostics.requestedMode }
        package var effectiveMode: SearchMode { diagnostics.effectiveMode }
        package var queryEmbeddingState: RAGContext.QueryEmbeddingState {
            diagnostics.queryEmbeddingState
        }

        package init(context: RAGContext, diagnostics: RAGContext.Diagnostics) {
            var context = context
            context.diagnostics = diagnostics
            self.context = context
            self.diagnostics = diagnostics
        }
    }

    /// Runtime stats DTO exposed to external callers.
    package struct RuntimeStats: Sendable, Equatable {
        package var frameCount: UInt64
        package var pendingFrames: UInt64
        package var generation: UInt64
        package var wal: WaxWALStats
        package var storeURL: URL
        package var vectorSearchEnabled: Bool
        package var queryEmbedderConfigured: Bool
        package var queryEmbedderReady: Bool
        package var queryEmbeddingCircuitOpen: Bool
        package var structuredMemoryEnabled: Bool
        package var accessStatsScoringEnabled: Bool
        package var embedderIdentity: EmbeddingIdentity?
        package var embeddingStatus: EmbeddingStatus
        package var framesWithoutVectors: UInt64
        /// Stored vectors come from a superseded model revision; vector search is off until
        /// ``MemoryOrchestrator/backfillUnembedded()`` re-embeds every live frame.
        package var vectorsNeedReembed: Bool

        package init(
            frameCount: UInt64,
            pendingFrames: UInt64,
            generation: UInt64,
            wal: WaxWALStats,
            storeURL: URL,
            vectorSearchEnabled: Bool,
            queryEmbedderConfigured: Bool,
            queryEmbedderReady: Bool,
            queryEmbeddingCircuitOpen: Bool,
            structuredMemoryEnabled: Bool,
            accessStatsScoringEnabled: Bool,
            embedderIdentity: EmbeddingIdentity?,
            embeddingStatus: EmbeddingStatus = .disabled,
            framesWithoutVectors: UInt64 = 0,
            vectorsNeedReembed: Bool = false
        ) {
            self.frameCount = frameCount
            self.pendingFrames = pendingFrames
            self.generation = generation
            self.wal = wal
            self.storeURL = storeURL
            self.vectorSearchEnabled = vectorSearchEnabled
            self.queryEmbedderConfigured = queryEmbedderConfigured
            self.queryEmbedderReady = queryEmbedderReady
            self.queryEmbeddingCircuitOpen = queryEmbeddingCircuitOpen
            self.structuredMemoryEnabled = structuredMemoryEnabled
            self.accessStatsScoringEnabled = accessStatsScoringEnabled
            self.embedderIdentity = embedderIdentity
            self.embeddingStatus = embeddingStatus
            self.framesWithoutVectors = framesWithoutVectors
            self.vectorsNeedReembed = vectorsNeedReembed
        }
    }

    package struct SessionRuntimeStats: Sendable, Equatable {
        package var active: Bool
        package var sessionId: UUID?
        package var sessionFrameCount: Int
        package var sessionTokenEstimate: Int
        package var pendingFramesStoreWide: UInt64
        package var countsIncludePending: Bool

        package init(
            active: Bool,
            sessionId: UUID?,
            sessionFrameCount: Int,
            sessionTokenEstimate: Int,
            pendingFramesStoreWide: UInt64,
            countsIncludePending: Bool
        ) {
            self.active = active
            self.sessionId = sessionId
            self.sessionFrameCount = sessionFrameCount
            self.sessionTokenEstimate = sessionTokenEstimate
            self.pendingFramesStoreWide = pendingFramesStoreWide
            self.countsIncludePending = countsIncludePending
        }
    }

    package struct HandoffRecord: Sendable, Equatable {
        package var frameId: UInt64
        package var timestampMs: Int64
        package var content: String
        package var project: String?
        package var pendingTasks: [String]

        package init(frameId: UInt64, timestampMs: Int64, content: String, project: String?, pendingTasks: [String]) {
            self.frameId = frameId
            self.timestampMs = timestampMs
            self.content = content
            self.project = project
            self.pendingTasks = pendingTasks
        }
    }
}
