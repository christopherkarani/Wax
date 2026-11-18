import Foundation
import WaxCore

extension AgentBrokerService {
    // Unscoped corpus stays cross-session. A bound session_id applies the same
    // project fence as search so ForeignLab durable does not leak.
    func corpusSearch(_ command: BrokerCommand.CorpusSearch) async throws -> AgentBrokerValue {
        let query = command.query
        let recursive = command.recursive
        let rebuild = command.rebuild
        let mode = command.mode
        let topK = command.topK
        let corpusNoEmbedder: Bool = switch mode {
        case .textOnly: true
        case .vectorOnly: false
        case .hybrid: noEmbedder
        }
        let buildSummary: BrokerCorpusBuildSummary?
        if rebuild || !FileManager.default.fileExists(atPath: corpusStoreURL.path) {
            buildSummary = try await BrokerCorpusStoreBuilder.build(
                sessionsDirectory: sessionRootURL,
                targetStoreURL: corpusStoreURL,
                noEmbedder: corpusNoEmbedder,
                embedderChoice: embedderChoice,
                embedderTuning: embedderTuning,
                recursive: recursive
            )
        } else {
            buildSummary = nil
        }
        let execution = try await endedSessions.withMemory(
            at: corpusStoreURL,
            noEmbedder: corpusNoEmbedder
        ) { memory in
            try await memory.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: nil,
                timeRange: nil
            )
        }

        // Disk rebuild skips stores held under exclusive flock. Active sessions in this
        // broker process are still part of "broker-managed session history" and must be
        // searchable via the live MemoryOrchestrator already open for each session.
        let corpusHits: [BrokerCorpusMergeHit] = execution.hits.compactMap { hit in
            let preview = agentFacingPreview(hit.previewText)
            return BrokerCorpusMergeHit.fromIndexedHit(
                frameId: hit.frameId,
                score: hit.score,
                sources: hit.sources,
                preview: preview,
                metadata: hit.metadata,
                defaultOrigin: .sessionStore
            )
        }

        let orderedActiveSessions = activeSessions.values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        var activeSessionHitGroups: [[BrokerCorpusMergeHit]] = []
        let longTermExecution = try await longTermMemory.searchExecution(
            query: query,
            mode: mode,
            topK: topK,
            frameFilter: nil,
            timeRange: nil
        )
        let longTermHits: [BrokerCorpusMergeHit] = longTermExecution.hits.map { hit in
            let preview = agentFacingPreview(hit.previewText)
            var metadata = hit.metadata
            metadata[BrokerCorpusMetadataKeys.sourceStorePath] = longTermStoreURL.path
            metadata[BrokerCorpusMetadataKeys.sourceStoreName] = longTermStoreURL.lastPathComponent
            metadata[BrokerCorpusMetadataKeys.sourceFrameID] = String(hit.frameId)
            return BrokerCorpusMergeHit.fromIndexedHit(
                frameId: hit.frameId,
                score: hit.score,
                sources: hit.sources,
                preview: preview,
                metadata: metadata,
                origin: .longTerm
            )
        }
        if !longTermHits.isEmpty {
            activeSessionHitGroups.append(longTermHits)
        }
        activeSessionHitGroups.reserveCapacity(orderedActiveSessions.count + 1)
        for state in orderedActiveSessions {
            let sessionExecution = try await state.memory.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: nil,
                timeRange: nil
            )
            let group: [BrokerCorpusMergeHit] = sessionExecution.hits.map { hit in
                let preview = agentFacingPreview(hit.previewText)
                let storePath = state.storeURL.path
                let metadata = BrokerCorpusHitMerge.annotateActiveSessionMetadata(
                    base: hit.metadata,
                    storePath: storePath,
                    storeName: state.storeURL.lastPathComponent,
                    frameId: hit.frameId,
                    sessionID: state.id.uuidString
                )
                return BrokerCorpusMergeHit.fromIndexedHit(
                    frameId: hit.frameId,
                    score: hit.score,
                    sources: hit.sources,
                    preview: preview,
                    metadata: metadata,
                    origin: .activeSession
                )
            }
            activeSessionHitGroups.append(group)
        }

        var merged = BrokerCorpusHitMerge.merge(
            corpusHits: corpusHits,
            activeSessionHitGroups: activeSessionHitGroups,
            topK: topK
        )
        if let sessionID = command.sessionID {
            let writeScope = writeScope(for: sessionID)
            let identity = LayeredRecall.Identity(
                project: writeScope.projectName,
                repo: writeScope.repoName
            )
            merged = Self.filterCorpusHits(merged, identity: identity)
        }
        let activeSessionsSearched = orderedActiveSessions.count

        var results: [AgentBrokerValue] = []
        results.reserveCapacity(merged.count)
        for (index, hit) in merged.enumerated() {
            var object: [String: AgentBrokerValue] = [
                "rank": .from(index + 1),
                "frameId": .from(hit.frameId),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "preview": .string(hit.preview),
                "metadata": .object(Self.publicCorpusMetadata(hit.metadata).mapValues(AgentBrokerValue.string)),
            ]
            if command.expand || index < 3 {
                object["text"] = .string(await corpusHitFullText(hit))
            }
            results.append(.object(object))
        }
        let buildValue: AgentBrokerValue = if let buildSummary {
            .object([
                "performed": .bool(true),
                "stores_discovered": .from(buildSummary.storesDiscovered),
                "stores_indexed": .from(buildSummary.storesIndexed),
                "stores_skipped": .from(buildSummary.storesSkipped),
                "documents_indexed": .from(buildSummary.documentsIndexed),
                "documents_skipped": .from(buildSummary.documentsSkipped),
                "active_sessions_searched": .from(activeSessionsSearched),
            ])
        } else {
            .object([
                "performed": .bool(false),
                "active_sessions_searched": .from(activeSessionsSearched),
            ])
        }
        let text = results.isEmpty ? "No results." : results.map(\.debugJSONString).joined(separator: "\n")
        return .object([
            "query": .string(query),
            "topK": .from(topK),
            "requested_mode": .string(execution.requestedMode.diagnosticsSummary),
            "effective_mode": .string(execution.effectiveMode.diagnosticsSummary),
            "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
            "recursive": .from(recursive),
            "rebuild_requested": .from(rebuild),
            "build": buildValue,
            "results": .array(results),
            "display_text": .string(text),
        ])
    }

    static func filterCorpusHits(
        _ hits: [BrokerCorpusMergeHit],
        identity: LayeredRecall.Identity
    ) -> [BrokerCorpusMergeHit] {
        hits.filter { BrokerRecall.allowsCorpusSearchHit($0, identity: identity) }
    }

    /// Omit store paths from the MCP/broker JSON. Keep origin and frame ids.
    static func publicCorpusMetadata(_ metadata: [String: String]) -> [String: String] {
        var copy = metadata
        copy.removeValue(forKey: BrokerCorpusMetadataKeys.sourceStorePath)
        return copy
    }

    func corpusHitFullText(_ hit: BrokerCorpusMergeHit) async -> String {
        switch hit.origin {
        case .longTerm, .activeSession:
            if let memory = memoryForCorpusHit(hit) {
                let frameID = await bestEffortCanonicalDocumentFrameID(for: hit.frameId, memory: memory) ?? hit.frameId
                if let text = await frameText(frameID: frameID, memory: memory),
                   text.utf8.count >= hit.preview.utf8.count {
                    return text
                }
            }
            return await corpusHitTextFromSourceStorePath(hit) ?? hit.preview
        case .sessionStore:
            return await fetchTrustedSessionStoreCorpusHitText(hit) ?? hit.preview
        }
    }

    func memoryForCorpusHit(_ hit: BrokerCorpusMergeHit) -> MemoryOrchestrator? {
        switch hit.origin {
        case .longTerm:
            return longTermMemory
        case .activeSession:
            guard let raw = hit.metadata["session_id"], let sessionID = UUID(uuidString: raw) else {
                return nil
            }
            return activeSessions[sessionID]?.memory
        case .sessionStore:
            // Live orchestrators are not held for ended session stores. Expand
            // opens `trustedSessionStoreURL` through `endedSessions.withMemory`.
            return nil
        }
    }

    func trustedSessionStoreURL(for hit: BrokerCorpusMergeHit) -> URL? {
        guard hit.origin == .sessionStore else { return nil }
        guard case .sessionStore(let url) = hit.fetchCase else { return nil }
        guard isTrustedCorpusStoreURL(url) else { return nil }
        return url
    }

    func fetchTrustedSessionStoreCorpusHitText(_ hit: BrokerCorpusMergeHit) async -> String? {
        guard let sourceURL = trustedSessionStoreURL(for: hit) else { return nil }
        let sourceFrameID = hit.metadata[BrokerCorpusMetadataKeys.sourceFrameID].flatMap(UInt64.init) ?? hit.frameId
        if let session = activeSessions.values.first(where: {
            $0.storeURL.standardizedFileURL.path == sourceURL.path
        }) {
            if let text = await frameText(frameID: sourceFrameID, memory: session.memory) {
                return text
            }
        }
        let fetched = try? await endedSessions.withMemory(
            at: sourceURL,
            noEmbedder: true
        ) { memory in
            if let data = try? await memory.wax.frameContent(frameId: sourceFrameID),
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                return text
            }
            return (try? await memory.corpusSourceDocuments()
                .first(where: { $0.frameId == sourceFrameID })?.text) ?? ""
        }
        if let fetched, fetched.isEmpty == false {
            return fetched
        }
        return nil
    }

    func corpusHitTextFromSourceStorePath(_ hit: BrokerCorpusMergeHit) async -> String? {
        guard let path = hit.metadata[BrokerCorpusMetadataKeys.sourceStorePath], !path.isEmpty else {
            return nil
        }
        let sourceFrameID = hit.metadata[BrokerCorpusMetadataKeys.sourceFrameID].flatMap(UInt64.init) ?? hit.frameId
        let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
        if sourceURL.path == longTermStoreURL.standardizedFileURL.path {
            return await frameText(frameID: sourceFrameID, memory: longTermMemory)
        }
        if let session = activeSessions.values.first(where: {
            $0.storeURL.standardizedFileURL.path == sourceURL.path
        }) {
            return await frameText(frameID: sourceFrameID, memory: session.memory)
        }
        guard isTrustedCorpusStoreURL(sourceURL) else { return nil }
        let fetched = try? await endedSessions.withMemory(
            at: sourceURL,
            noEmbedder: true
        ) { memory in
            if let data = try? await memory.wax.frameContent(frameId: sourceFrameID),
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                return text
            }
            return (try? await memory.corpusSourceDocuments()
                .first(where: { $0.frameId == sourceFrameID })?.text) ?? ""
        }
        if let fetched, fetched.isEmpty == false {
            return fetched
        }
        return nil
    }

    func isTrustedCorpusStoreURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == longTermStoreURL.standardizedFileURL.path {
            return true
        }
        let root = sessionRootURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}
