import Foundation
import WaxCore
import WaxVectorSearch

package struct EndedSessionSearchQuery: Sendable {
    package var manifest: BrokerSessionManifest
    package var query: String
    package var mode: Memory.RetrievalMode
    package var topK: Int

    package init(
        manifest: BrokerSessionManifest,
        query: String,
        mode: Memory.RetrievalMode,
        topK: Int
    ) {
        self.manifest = manifest
        self.query = query
        self.mode = mode
        self.topK = topK
    }
}

package struct EndedSessionRecallQuery: Sendable {
    package var manifest: BrokerSessionManifest
    package var query: String
    package var mode: Memory.RetrievalMode
    package var topK: Int
    package var frameFilter: FrameFilter?

    package init(
        manifest: BrokerSessionManifest,
        query: String,
        mode: Memory.RetrievalMode,
        topK: Int,
        frameFilter: FrameFilter?
    ) {
        self.manifest = manifest
        self.query = query
        self.mode = mode
        self.topK = topK
        self.frameFilter = frameFilter
    }
}

package struct EndedSessionDocumentQuery: Sendable {
    package var sessionID: UUID
    package var frameID: UInt64

    package init(sessionID: UUID, frameID: UInt64) {
        self.sessionID = sessionID
        self.frameID = frameID
    }
}

package struct EndedSessionDocument: Sendable, Equatable {
    package var sessionID: UUID
    package var frameID: UInt64
    package var text: String
    package var metadata: [String: String]
    package var timestampMs: Int64
    package var agentID: String?
    package var runID: String?

    package init(
        sessionID: UUID,
        frameID: UInt64,
        text: String,
        metadata: [String: String],
        timestampMs: Int64,
        agentID: String? = nil,
        runID: String? = nil
    ) {
        self.sessionID = sessionID
        self.frameID = frameID
        self.text = text
        self.metadata = metadata
        self.timestampMs = timestampMs
        self.agentID = agentID
        self.runID = runID
    }
}

/// Ended virtual-session I/O: list manifests, search, recall, get-by-id.
/// Working-lane and durable `MemoryOrchestrator` stay outside this module.
package protocol EndedSessionStore: Sendable {
    func listManifests() throws -> [BrokerSessionManifest]
    func search(_ query: EndedSessionSearchQuery) async throws -> [LayeredRecall.EpisodicLaneHit]
    func recall(_ query: EndedSessionRecallQuery) async throws -> [LayeredRecall.Hit]
    func document(_ query: EndedSessionDocumentQuery) async throws -> EndedSessionDocument
}

package struct InMemoryEndedSessionStore: EndedSessionStore {
    package var manifests: [BrokerSessionManifest]
    package var searchHits: [UUID: [LayeredRecall.EpisodicLaneHit]]
    package var recallHits: [UUID: [LayeredRecall.Hit]]
    package var documents: [EndedSessionDocument]

    package init(
        manifests: [BrokerSessionManifest] = [],
        searchHits: [UUID: [LayeredRecall.EpisodicLaneHit]] = [:],
        recallHits: [UUID: [LayeredRecall.Hit]] = [:],
        documents: [EndedSessionDocument] = []
    ) {
        self.manifests = manifests
        self.searchHits = searchHits
        self.recallHits = recallHits
        self.documents = documents
    }

    package func listManifests() throws -> [BrokerSessionManifest] {
        manifests
    }

    package func search(_ query: EndedSessionSearchQuery) async throws -> [LayeredRecall.EpisodicLaneHit] {
        searchHits[query.manifest.sessionID] ?? []
    }

    package func recall(_ query: EndedSessionRecallQuery) async throws -> [LayeredRecall.Hit] {
        recallHits[query.manifest.sessionID] ?? []
    }

    package func document(_ query: EndedSessionDocumentQuery) async throws -> EndedSessionDocument {
        guard let document = documents.first(where: {
            $0.sessionID == query.sessionID && $0.frameID == query.frameID
        }) else {
            throw BrokerValidationError.invalid("No memory document found for frame_id \(query.frameID)")
        }
        return document
    }
}

package struct DiskEndedSessionStore: EndedSessionStore {
    package let sessionRootURL: URL
    private let enableAccessStatsScoring: Bool
    private let scopeContext: MemoryScopeContext
    private let defaultNoEmbedder: Bool
    private let embedderChoice: String
    private let embedderTuning: CommandLineEmbedderRuntimeTuning
    private let readiness: EmbeddingReadiness
    private let factoryOverride: (@Sendable () async throws -> any EmbeddingProvider)?

    package init(
        sessionRootURL: URL,
        noEmbedder: Bool,
        embedderChoice: String = "auto",
        enableAccessStatsScoring: Bool = true,
        scopeContext: MemoryScopeContext = MemoryScopeContext(),
        embedderTuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment(),
        readiness: EmbeddingReadiness = .shared,
        factoryOverride: (@Sendable () async throws -> any EmbeddingProvider)? = nil
    ) {
        self.sessionRootURL = sessionRootURL
        self.enableAccessStatsScoring = enableAccessStatsScoring
        self.scopeContext = scopeContext
        self.defaultNoEmbedder = noEmbedder
        self.embedderChoice = embedderChoice
        self.embedderTuning = embedderTuning
        self.readiness = readiness
        self.factoryOverride = factoryOverride
    }

    package func listManifests() throws -> [BrokerSessionManifest] {
        guard FileManager.default.fileExists(atPath: sessionRootURL.path) else { return [] }
        return try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
    }

    package func loadManifest(sessionID: UUID) throws -> BrokerSessionManifest {
        try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
    }

    package func search(_ query: EndedSessionSearchQuery) async throws -> [LayeredRecall.EpisodicLaneHit] {
        guard let sessionURL = Self.resolvedStoreFileURL(
            path: query.manifest.storePath,
            reclaimedAtMs: query.manifest.reclaimedAtMs
        ) else { return [] }
        return try await withMemory(at: sessionURL) { memory in
            let execution = try await memory.searchExecution(
                query: query.query,
                mode: query.mode,
                topK: query.topK,
                frameFilter: nil,
                timeRange: nil
            )
            let signals = BrokerSessionPersistence.recallSignals(
                from: try BrokerSessionPersistence.loadEvents(
                    from: URL(fileURLWithPath: query.manifest.eventLogPath)
                )
            )
            var laneHits: [LayeredRecall.EpisodicLaneHit] = []
            laneHits.reserveCapacity(execution.hits.count)
            for hit in execution.hits {
                let canonicalFrameID = await canonicalFrameID(for: hit.frameId, memory: memory)
                let signal = canonicalFrameID.flatMap { signals[$0] } ?? signals[hit.frameId]
                laneHits.append(
                    LayeredRecall.EpisodicLaneHit(
                        frameID: hit.frameId,
                        score: hit.score,
                        previewText: hit.previewText,
                        metadata: hit.metadata,
                        explanations: hit.explanations,
                        canonicalFrameID: canonicalFrameID,
                        recallCount: signal.map(\.recallCount),
                        uniqueQueryCount: signal.map(\.uniqueQueryCount)
                    )
                )
            }
            return laneHits
        }
    }

    package func recall(_ query: EndedSessionRecallQuery) async throws -> [LayeredRecall.Hit] {
        guard let sessionURL = Self.resolvedStoreFileURL(
            path: query.manifest.storePath,
            reclaimedAtMs: query.manifest.reclaimedAtMs
        ) else { return [] }
        return try await withMemory(at: sessionURL) { memory in
            let items = try await memory.recallExecution(
                query: query.query,
                mode: query.mode,
                frameFilter: query.frameFilter,
                timeRange: nil,
                topK: query.topK
            ).context.items
            var hits: [LayeredRecall.Hit] = []
            hits.reserveCapacity(items.count)
            for item in items {
                let canonicalFrameID = await canonicalFrameID(for: item.frameId, memory: memory)
                    ?? item.frameId
                hits.append(
                    LayeredRecall.Hit(
                        id: .episodic(sessionID: query.manifest.sessionID, frameID: canonicalFrameID),
                        agentID: query.manifest.agentID,
                        runID: query.manifest.runID,
                        score: item.score,
                        text: item.text,
                        preview: MemorySemantics.summarizeCandidate(item.text, maxLength: 180),
                        metadata: item.metadata,
                        explanations: ["recent session episode"] + item.explanations,
                        timestampMs: query.manifest.updatedAtMs,
                        kind: item.kind,
                        sources: item.sources
                    )
                )
            }
            return hits
        }
    }

    package func document(_ query: EndedSessionDocumentQuery) async throws -> EndedSessionDocument {
        let manifest = try loadManifest(sessionID: query.sessionID)
        guard let sessionURL = Self.resolvedStoreFileURL(
            path: manifest.storePath,
            reclaimedAtMs: manifest.reclaimedAtMs
        ) else {
            throw BrokerValidationError.invalid(
                "No ended-session store for session_id \(query.sessionID.uuidString)"
            )
        }
        return try await withMemory(at: sessionURL) { memory in
            guard let document = try await memory.corpusSourceDocuments()
                .first(where: { $0.frameId == query.frameID })
            else {
                throw BrokerValidationError.invalid("No memory document found for frame_id \(query.frameID)")
            }
            await memory.recordAccess(frameId: document.frameId)
            return EndedSessionDocument(
                sessionID: query.sessionID,
                frameID: document.frameId,
                text: document.text,
                metadata: document.metadata,
                timestampMs: document.timestampMs,
                agentID: manifest.agentID,
                runID: manifest.runID
            )
        }
    }

    package func withMemory<T: Sendable>(
        at url: URL,
        noEmbedder: Bool? = nil,
        _ body: @Sendable (MemoryOrchestrator) async throws -> T
    ) async throws -> T {
        guard let fileURL = Self.resolvedStoreFileURL(path: url.path, reclaimedAtMs: nil) else {
            throw BrokerValidationError.invalid(
                "Ended-session store path is missing or not a file: \(url.path)"
            )
        }
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = false
        config.enableAccessStatsScoring = enableAccessStatsScoring
        config.defaultScopeContext = scopeContext
        let request = try HostEmbeddingReadiness.request(
            noEmbedder: noEmbedder ?? defaultNoEmbedder,
            requireVector: false,
            embedderChoice: embedderChoice,
            options: BuiltInEmbeddingProviderOptions(tuning: embedderTuning)
        )
        let memory = try await EmbeddingReadinessBinding.openOrchestrator(
            at: fileURL,
            config: config,
            request: request,
            waxOptions: CommandLineEmbedderFactory.waxOptions(),
            readiness: readiness,
            factoryOverride: factoryOverride
        )
        do {
            let result = try await body(memory)
            try await memory.close()
            return result
        } catch {
            try? await memory.close()
            throw error
        }
    }

    /// Reclaim tombstones set `storePath` to `""`. `URL(fileURLWithPath: "")` is CWD.
    private static func resolvedStoreFileURL(path: String, reclaimedAtMs: Int64?) -> URL? {
        guard reclaimedAtMs == nil else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              isDirectory.boolValue == false
        else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    private func canonicalFrameID(for frameID: UInt64, memory: MemoryOrchestrator) async -> UInt64? {
        do {
            return try await memory.canonicalDocumentFrameID(for: frameID)
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "ended-session canonical frame lookup",
                fallback: "skip stale search hit"
            )
            return nil
        }
    }
}
