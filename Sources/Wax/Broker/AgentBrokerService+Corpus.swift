import Foundation
import WaxCore

extension AgentBrokerService {
    func entityUpsert(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let key = try args.requiredString("key", maxBytes: Self.maxGraphIdentifierBytes)
        let kind = try args.requiredString("kind", maxBytes: Self.maxGraphKindBytes)
        let aliases = try args.optionalStringArray("aliases") ?? []
        let entityID = try await longTermMemory.upsertEntity(
            key: EntityKey(key),
            kind: kind,
            aliases: aliases,
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "entity_id": .from(entityID.rawValue),
            "key": .string(key),
            "committed": .bool(true),
        ])
    }

    func factAssert(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let subject = try args.requiredString("subject", maxBytes: Self.maxGraphIdentifierBytes)
        let predicate = try args.requiredString("predicate", maxBytes: Self.maxGraphIdentifierBytes)
        let objectValue = try args.requiredValue("object")
        let relation = try parseVersionRelation(try args.optionalString("relation") ?? "sets")
        let evidence = try parseStructuredEvidence(args.optionalValue("evidence"))
        let factID = try await longTermMemory.assertFact(
            subject: EntityKey(subject),
            predicate: PredicateKey(predicate),
            object: try parseFactValue(objectValue),
            relation: relation,
            validFromMs: try args.optionalInt64("valid_from"),
            validToMs: try args.optionalInt64("valid_to"),
            evidence: evidence,
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "fact_id": .from(factID.rawValue),
            "evidence_count": .from(evidence.count),
            "committed": .bool(true),
        ])
    }

    func factRetract(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let factID = try args.requiredInt64("fact_id")
        let atMs = try args.optionalInt64("at_ms")
        try await longTermMemory.retractFact(factId: FactRowID(rawValue: factID), atMs: atMs, commit: true)
        return .object([
            "status": .string("ok"),
            "fact_id": .from(factID),
            "at_ms": .from(atMs),
            "committed": .bool(true),
        ])
    }

    func factsQuery(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let limit = try args.optionalInt("limit") ?? 20
        guard (1...Self.maxGraphLimit).contains(limit) else {
            throw BrokerValidationError.invalid("limit must be between 1 and \(Self.maxGraphLimit)")
        }
        let subject = try args.optionalString("subject").map { EntityKey($0) }
        let predicate = try args.optionalString("predicate").map { PredicateKey($0) }
        let asOfMs = try args.optionalInt64("as_of") ?? Int64.max
        let systemAsOfMs = try args.optionalInt64("system_as_of")
        let validAsOfMs = try args.optionalInt64("valid_as_of")
        let result = try await longTermMemory.facts(
            about: subject,
            predicate: predicate,
            asOfMs: asOfMs,
            systemAsOfMs: systemAsOfMs,
            validAsOfMs: validAsOfMs,
            limit: limit
        )
        let effectiveSystemAsOfMs = systemAsOfMs ?? asOfMs
        let effectiveValidAsOfMs = validAsOfMs ?? asOfMs
        let hits: [AgentBrokerValue] = result.hits.map { hit in
            AgentBrokerValue.object([
                "fact_id": .from(hit.factId.rawValue),
                "span_id": .from(hit.spanId),
                "subject": .string(hit.fact.subject.rawValue),
                "predicate": .string(hit.fact.predicate.rawValue),
                "object": factValueAsBrokerValue(hit.fact.object),
                "relation": .string(hit.relation.wireName),
                "valid_from_ms": .from(hit.valid.fromMs),
                "valid_to_ms": hit.valid.toMs.map(AgentBrokerValue.from) ?? .null,
                "system_from_ms": .from(hit.system.fromMs),
                "system_to_ms": hit.system.toMs.map(AgentBrokerValue.from) ?? .null,
                "is_open_ended": .from(hit.isOpenEnded),
                "evidence_count": .from(hit.evidence.count),
                "evidence": .array(hit.evidence.map(renderStructuredEvidence)),
            ])
        }
        return .object([
            "count": .from(result.hits.count),
            "truncated": .from(result.wasTruncated),
            "as_of": .from(asOfMs),
            "system_as_of": .from(effectiveSystemAsOfMs),
            "valid_as_of": .from(effectiveValidAsOfMs),
            "hits": .array(hits),
        ])
    }

    func entityResolve(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let alias = try args.requiredString("alias", maxBytes: Self.maxGraphIdentifierBytes)
        let limit = try args.optionalInt("limit") ?? 10
        let matches = try await longTermMemory.resolveEntities(matchingAlias: alias, limit: limit)
        let entities: [AgentBrokerValue] = matches.map { match in
            .object([
                "id": .from(match.id),
                "key": .string(match.key.rawValue),
                "kind": .string(match.kind),
            ])
        }
        return .object([
            "count": .from(matches.count),
            "entities": .array(entities),
        ])
    }

    func corpusSearch(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let query = try args.requiredString("query", maxBytes: Self.maxContentBytes)
        let recursive = try args.optionalBool("recursive") ?? true
        let rebuild = try args.optionalBool("rebuild") ?? true
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try parseSearchMode(modeRaw: modeRaw, alpha: try args.optionalDouble("alpha"))
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...Self.maxTopK).contains(topK) else {
            throw BrokerValidationError.invalid("topK must be between 1 and \(Self.maxTopK)")
        }
        let corpusNoEmbedder: Bool = switch mode {
        case .text: true
        case .vector: false
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
        let execution = try await openAdhocMemory(
            at: corpusStoreURL,
            structuredMemoryEnabled: false,
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
        let corpusHits: [BrokerCorpusMergeHit] = execution.hits.map { hit in
            let preview = hit.previewText ?? ""
            let sourcePath = hit.metadata[BrokerCorpusMetadataKeys.sourceStorePath] ?? ""
            return BrokerCorpusMergeHit(
                frameId: hit.frameId,
                score: hit.score,
                sources: hit.sources.map(\.rawValue),
                preview: preview,
                metadata: hit.metadata,
                dedupeKey: BrokerCorpusMergeHit.makeDedupeKey(
                    sourcePath: sourcePath,
                    frameId: hit.frameId,
                    preview: preview
                )
            )
        }

        let orderedActiveSessions = activeSessions.values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        var activeSessionHitGroups: [[BrokerCorpusMergeHit]] = []
        activeSessionHitGroups.reserveCapacity(orderedActiveSessions.count)
        for state in orderedActiveSessions {
            let sessionExecution = try await state.memory.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: nil,
                timeRange: nil
            )
            let group: [BrokerCorpusMergeHit] = sessionExecution.hits.map { hit in
                let preview = hit.previewText ?? ""
                let storePath = state.storeURL.path
                let metadata = BrokerCorpusHitMerge.annotateActiveSessionMetadata(
                    base: hit.metadata,
                    storePath: storePath,
                    storeName: state.storeURL.lastPathComponent,
                    frameId: hit.frameId,
                    sessionID: state.id.uuidString
                )
                return BrokerCorpusMergeHit(
                    frameId: hit.frameId,
                    score: hit.score,
                    sources: hit.sources.map(\.rawValue),
                    preview: preview,
                    metadata: metadata,
                    dedupeKey: BrokerCorpusMergeHit.makeDedupeKey(
                        sourcePath: storePath,
                        frameId: hit.frameId,
                        preview: preview
                    )
                )
            }
            activeSessionHitGroups.append(group)
        }

        let merged = BrokerCorpusHitMerge.merge(
            corpusHits: corpusHits,
            activeSessionHitGroups: activeSessionHitGroups,
            topK: topK
        )
        let activeSessionsSearched = orderedActiveSessions.count

        let results: [AgentBrokerValue] = merged.enumerated().map { index, hit in
            .object([
                "rank": .from(index + 1),
                "frameId": .from(hit.frameId),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0) }),
                "preview": .string(hit.preview),
                "metadata": .object(hit.metadata.mapValues(AgentBrokerValue.string)),
            ])
        }
        let buildValue: AgentBrokerValue = if let buildSummary {
            .object([
                "performed": .bool(true),
                "stores_discovered": .from(buildSummary.storesDiscovered),
                "stores_indexed": .from(buildSummary.storesIndexed),
                "stores_skipped": .from(buildSummary.storesSkipped),
                "documents_indexed": .from(buildSummary.documentsIndexed),
                "documents_skipped": .from(buildSummary.documentsSkipped),
                "corpus_store_path": .string(buildSummary.targetStorePath),
                "active_sessions_searched": .from(activeSessionsSearched),
            ])
        } else {
            .object([
                "performed": .bool(false),
                "corpus_store_path": .string(corpusStoreURL.path),
                "active_sessions_searched": .from(activeSessionsSearched),
            ])
        }
        let text = results.isEmpty ? "No results." : results.map(\.debugJSONString).joined(separator: "\n")
        return .object([
            "query": .string(query),
            "topK": .from(topK),
            "requested_mode": .string(execution.requestedModeSummary),
            "effective_mode": .string(execution.effectiveModeSummary),
            "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
            "recursive": .from(recursive),
            "rebuild_requested": .from(rebuild),
            "build": buildValue,
            "results": .array(results),
            "display_text": .string(text),
        ])
    }
}
