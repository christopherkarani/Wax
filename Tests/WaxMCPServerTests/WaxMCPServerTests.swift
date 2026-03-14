import Foundation
import Testing

#if MCPServer
import MCP
@testable import wax_mcp
import Wax

@Test
func toolsListContainsExpectedTools() {
    let names = Set(ToolSchemas.allTools.map(\.name))
    #expect(names.contains("wax_remember"))
    #expect(names.contains("wax_recall"))
    #expect(names.contains("wax_search"))
    #expect(names.contains("wax_flush"))
    #expect(names.contains("wax_stats"))
    #expect(names.contains("wax_session_start"))
    #expect(names.contains("wax_session_end"))
    #expect(names.contains("wax_handoff"))
    #expect(names.contains("wax_handoff_latest"))
    #expect(names.contains("wax_entity_upsert"))
    #expect(names.contains("wax_fact_assert"))
    #expect(names.contains("wax_fact_retract"))
    #expect(names.contains("wax_facts_query"))
    #expect(names.contains("wax_entity_resolve"))
    // Verify no duplicate tool names
    #expect(names.count == ToolSchemas.allTools.count)
}

@Test
func toolsListHonorsStructuredMemoryFlag() {
    let withStructuredMemory = Set(ToolSchemas.tools(structuredMemoryEnabled: true).map(\.name))
    let withoutStructuredMemory = Set(ToolSchemas.tools(structuredMemoryEnabled: false).map(\.name))
    #expect(withStructuredMemory.contains("wax_facts_query"))
    #expect(!withoutStructuredMemory.contains("wax_facts_query"))
    #expect(withStructuredMemory.contains("wax_entity_upsert"))
    #expect(!withoutStructuredMemory.contains("wax_entity_upsert"))
    #expect(!withoutStructuredMemory.contains("wax_fact_assert"))
}

@Test
func toolSchemaRegression() {
    let tools = ToolSchemas.allTools

    // No duplicate tool names
    let names = tools.map(\.name)
    let uniqueNames = Set(names)
    #expect(uniqueNames.count == names.count, "Duplicate tool names detected")

    // Every tool must have a non-empty name and description
    for tool in tools {
        #expect(!tool.name.isEmpty, "Tool has an empty name")
        #expect(!(tool.description ?? "").isEmpty, "Tool '\(tool.name)' has empty or nil description")
    }

    // Core tools must be present (regression: renaming or removing breaks clients)
    let requiredTools = ["wax_remember", "wax_recall", "wax_search", "wax_flush", "wax_stats"]
    for required in requiredTools {
        #expect(uniqueNames.contains(required), "Required tool '\(required)' is missing from schema")
    }

    // Core tool inputSchemas must be well-formed objects with a required field
    let coreSchemas: [(name: String, schema: Value)] = [
        ("wax_remember", ToolSchemas.waxRemember),
        ("wax_recall", ToolSchemas.waxRecall),
        ("wax_search", ToolSchemas.waxSearch),
    ]
    for (toolName, schema) in coreSchemas {
        guard let obj = schema.objectValue else {
            Issue.record("Schema for '\(toolName)' is not an object")
            continue
        }
        if case .string(let typeVal) = obj["type"] {
            #expect(typeVal == "object", "Schema for '\(toolName)' has unexpected type '\(typeVal)'")
        } else {
            Issue.record("Schema for '\(toolName)' is missing 'type' field")
        }
        #expect(obj["properties"] != nil, "Schema for '\(toolName)' is missing 'properties'")
        if case .array(let required) = obj["required"] {
            #expect(!required.isEmpty, "Schema for '\(toolName)' has no required fields")
        } else {
            Issue.record("Schema for '\(toolName)' is missing 'required' array")
        }
    }
}

@Test
func toolsRememberRecallSearchFlushStatsHappyPath() async throws {
    try await withMemory { memory in
        let rememberResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": "Swift actors isolate mutable state.",
                    "metadata": ["source": "test-suite", "rank": 1],
                ]
            ),
            memory: memory
        )
        #expect(rememberResult.isError != true)

        let flushResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory
        )
        #expect(flushResult.isError != true)
        #expect(firstText(in: flushResult).contains("Flushed."))

        let recallResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_recall", arguments: ["query": "actors", "limit": 3]),
            memory: memory
        )
        #expect(recallResult.isError != true)
        #expect(firstText(in: recallResult).contains("Query: actors"))

        let searchResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "actors", "mode": "text", "topK": 5]
            ),
            memory: memory
        )
        #expect(searchResult.isError != true)
        #expect(!firstText(in: searchResult).isEmpty)

        let statsResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory
        )
        #expect(statsResult.isError != true)
        #expect(firstText(in: statsResult).contains("\"frameCount\""))
    }
}

@Test
func rememberDefaultAutoCommitMakesDataImmediatelyRecallable() async throws {
    try await withMemory { memory in
        let seed = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let queryToken = "rememberautoquery\(seed.prefix(8))"
        let marker = "rememberautomarker\(seed.suffix(8))"
        let markerNeedle = String(marker.prefix(14))

        let rememberResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: ["content": .string("\(queryToken) \(marker)")]
            ),
            memory: memory
        )
        #expect(rememberResult.isError != true)
        let rememberJSON = try parseJSONText(in: rememberResult)
        #expect((rememberJSON["committed"] as? Bool) == true)

        let statsResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory
        )
        #expect(statsResult.isError != true)
        let statsJSON = try parseJSONText(in: statsResult)
        #expect((statsJSON["pendingFrames"] as? Int ?? -1) == 0)

        let recallResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_recall", arguments: ["query": .string(queryToken), "limit": .int(5)]),
            memory: memory
        )
        #expect(recallResult.isError != true)
        #expect(firstText(in: recallResult).contains(markerNeedle))
    }
}

@Test
func rememberCommitFalseBatchesUntilFlush() async throws {
    try await withMemory { memory in
        let seed = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let queryToken = "rememberbatchquery\(seed.prefix(8))"
        let marker = "rememberbatchmarker\(seed.suffix(8))"
        let markerNeedle = String(marker.prefix(14))

        let rememberResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": .string("\(queryToken) \(marker)"),
                    "commit": .bool(false),
                ]
            ),
            memory: memory
        )
        #expect(rememberResult.isError != true)
        let rememberJSON = try parseJSONText(in: rememberResult)
        #expect((rememberJSON["committed"] as? Bool) == false)

        let statsBeforeFlush = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory
        )
        #expect(statsBeforeFlush.isError != true)
        let statsBeforeFlushJSON = try parseJSONText(in: statsBeforeFlush)
        #expect((statsBeforeFlushJSON["pendingFrames"] as? Int ?? 0) > 0)

        let flushResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory
        )
        #expect(flushResult.isError != true)

        let statsAfterFlush = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory
        )
        #expect(statsAfterFlush.isError != true)
        let statsAfterFlushJSON = try parseJSONText(in: statsAfterFlush)
        #expect((statsAfterFlushJSON["pendingFrames"] as? Int ?? -1) == 0)

        let recallAfterFlush = await WaxMCPTools.handleCall(
            params: .init(name: "wax_recall", arguments: ["query": .string(queryToken), "limit": .int(5)]),
            memory: memory
        )
        #expect(recallAfterFlush.isError != true)
        #expect(firstText(in: recallAfterFlush).contains(markerNeedle))
    }
}

@Test
func handoffCommitFalseBatchesAndLatestOnlySeesCommittedFrames() async throws {
    try await withMemory { memory in
        let project = "handoff-batch-project-\(UUID().uuidString)"
        let marker = "handoff-batch-marker-\(UUID().uuidString)"

        let handoffResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_handoff",
                arguments: [
                    "content": .string(marker),
                    "project": .string(project),
                    "commit": false,
                ]
            ),
            memory: memory
        )
        #expect(handoffResult.isError != true)
        let handoffJSON = try parseJSONText(in: handoffResult)
        #expect((handoffJSON["committed"] as? Bool) == false)

        let statsBeforeFlush = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory
        )
        #expect(statsBeforeFlush.isError != true)
        let statsBeforeFlushJSON = try parseJSONText(in: statsBeforeFlush)
        #expect((statsBeforeFlushJSON["pendingFrames"] as? Int ?? 0) > 0)

        let latestBeforeFlush = await WaxMCPTools.handleCall(
            params: .init(name: "wax_handoff_latest", arguments: ["project": .string(project)]),
            memory: memory
        )
        #expect(latestBeforeFlush.isError != true)
        let latestBeforeFlushJSON = try parseJSONText(in: latestBeforeFlush)
        #expect((latestBeforeFlushJSON["found"] as? Bool) == false)

        let flushResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory
        )
        #expect(flushResult.isError != true)

        let latestAfterFlush = await WaxMCPTools.handleCall(
            params: .init(name: "wax_handoff_latest", arguments: ["project": .string(project)]),
            memory: memory
        )
        #expect(latestAfterFlush.isError != true)
        let latestAfterFlushJSON = try parseJSONText(in: latestAfterFlush)
        #expect((latestAfterFlushJSON["found"] as? Bool) == true)
        #expect((latestAfterFlushJSON["content"] as? String)?.contains(marker) == true)
    }
}

@Test
func recallAndSearchSupportMetadataExactFilters() async throws {
    try await withMemory { memory in
        let seed = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let queryToken = "metadatafilterquery\(seed.prefix(8))"
        let blockedMarker = "metadatablocked\(seed.suffix(8))"
        let allowedMarker = "metadataallowed\(seed.dropFirst(8).prefix(8))"
        let blockedNeedle = String(blockedMarker.prefix(12))
        let allowedNeedle = String(allowedMarker.prefix(12))

        let blockedRemember = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": .string("\(queryToken) \(blockedMarker)"),
                    "metadata": .object(["group": .string("blocked")]),
                ]
            ),
            memory: memory
        )
        #expect(blockedRemember.isError != true)

        let allowedRemember = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": .string("\(queryToken) \(allowedMarker)"),
                    "metadata": .object(["group": .string("allowed")]),
                ]
            ),
            memory: memory
        )
        #expect(allowedRemember.isError != true)

        let flushResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory
        )
        #expect(flushResult.isError != true)

        let baselineSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": .string(queryToken), "mode": .string("text"), "topK": .int(10)]
            ),
            memory: memory
        )
        #expect(baselineSearch.isError != true)
        #expect(firstText(in: baselineSearch).contains(blockedNeedle))

        let filteredSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: [
                    "query": .string(queryToken),
                    "mode": .string("text"),
                    "topK": .int(10),
                    "filters": .object([
                        "metadata": .object([
                            "exact": .object(["group": .string("allowed")]),
                        ]),
                    ]),
                ]
            ),
            memory: memory
        )
        #expect(filteredSearch.isError != true)
        #expect(firstText(in: filteredSearch).contains(allowedNeedle))
        #expect(!firstText(in: filteredSearch).contains(blockedNeedle))

        let baselineRecall = await WaxMCPTools.handleCall(
            params: .init(name: "wax_recall", arguments: ["query": .string(queryToken), "limit": .int(10)]),
            memory: memory
        )
        #expect(baselineRecall.isError != true)
        #expect(firstText(in: baselineRecall).contains(blockedNeedle))

        let filteredRecall = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_recall",
                arguments: [
                    "query": .string(queryToken),
                    "limit": .int(10),
                    "filters": .object([
                        "metadata": .object([
                            "exact": .object(["group": .string("allowed")]),
                        ]),
                    ]),
                ]
            ),
            memory: memory
        )
        #expect(filteredRecall.isError != true)
        #expect(firstText(in: filteredRecall).contains(allowedNeedle))
        #expect(!firstText(in: filteredRecall).contains(blockedNeedle))
    }
}

@Test
func recallValidatesModeAndSearchControls() async throws {
    try await withMemory { memory in
        let invalidMode = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_recall",
                arguments: ["query": "mode-validation", "mode": "invalid-mode"]
            ),
            memory: memory
        )
        #expect(invalidMode.isError == true)
        #expect(firstText(in: invalidMode).contains("mode"))

        let invalidTopK = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_recall",
                arguments: ["query": "topk-validation", "search_top_k": 0]
            ),
            memory: memory
        )
        #expect(invalidTopK.isError == true)
        #expect(firstText(in: invalidTopK).contains("search_top_k"))
    }
}

@Test
func toolsReturnValidationErrorForMissingArguments() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "wax_remember", arguments: [:]),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("Missing required argument"))
    }
}

@Test
func toolsRejectNonIntegralAndOutOfRangeNumericArguments() async throws {
    try await withMemory { memory in
        let fractional = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "actors", "topK": 1.9]
            ),
            memory: memory
        )
        #expect(fractional.isError == true)
        #expect(firstText(in: fractional).contains("topK must be an integer"))

        let outOfRange = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "actors", "topK": 1e100]
            ),
            memory: memory
        )
        #expect(outOfRange.isError == true)
        #expect(firstText(in: outOfRange).contains("topK is out of range"))
    }
}

@Test
func toolsRejectRecallLimitOutOfRange() async throws {
    try await withMemory { memory in
        let zero = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_recall",
                arguments: ["query": "actors", "limit": 0]
            ),
            memory: memory,
            structuredMemoryEnabled: true
        )
        #expect(zero.isError == true)
        #expect(firstText(in: zero).contains("limit must be between 1 and"))

        let tooHigh = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_recall",
                arguments: ["query": "actors", "limit": 101]
            ),
            memory: memory,
            structuredMemoryEnabled: true
        )
        #expect(tooHigh.isError == true)
        #expect(firstText(in: tooHigh).contains("limit must be between 1 and"))
    }
}

@Test
func toolsBlockStructuredMemoryOnlyToolsWhenDisabled() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: ["subject": "agent:codex", "limit": 10]
            ),
            memory: memory,
            structuredMemoryEnabled: false
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("structured memory"))
    }
}

@Test
func unknownToolReturnsErrorResult() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "wax_nope", arguments: [:]),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("Unknown tool"))
    }
}

@Test
func sessionStartEndAndScopedRecallSearchWork() async throws {
    try await withMemory { memory in
        let start = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_start", arguments: [:]),
            memory: memory
        )
        #expect(start.isError != true)
        let startJSON = try parseJSONText(in: start)
        let sessionID = try requireString(startJSON, key: "session_id")

        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: ["content": "GLOBAL_ONLY_ABC anchor for unscoped search"]
            ),
            memory: memory
        )
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": "SESSION_ONLY_XYZ anchor for scoped search",
                    "session_id": .string(sessionID),
                ]
            ),
            memory: memory
        )
        _ = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory
        )

        let scopedRecall = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_recall",
                arguments: ["query": "SESSION_ONLY_XYZ", "session_id": .string(sessionID), "limit": 10]
            ),
            memory: memory
        )
        #expect(scopedRecall.isError != true)
        let scopedRecallText = firstText(in: scopedRecall)
        #expect(scopedRecallText.contains("SESSION_ONLY_XYZ"))
        #expect(!scopedRecallText.contains("GLOBAL_ONLY_ABC"))

        let unscopedSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "GLOBAL_ONLY_ABC", "mode": "text", "topK": 10]
            ),
            memory: memory
        )
        #expect(unscopedSearch.isError != true)
        #expect(firstText(in: unscopedSearch).contains("GLOBAL"))

        let scopedSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: [
                    "query": "GLOBAL_ONLY_ABC",
                    "mode": "text",
                    "topK": .int(10),
                    "session_id": .string(sessionID),
                ]
            ),
            memory: memory
        )
        #expect(scopedSearch.isError != true)
        #expect(!firstText(in: scopedSearch).contains("GLOBAL_ONLY_ABC"))

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_end", arguments: [:]),
            memory: memory
        )
        #expect(end.isError != true)
    }
}

@Test
func sessionStartDoesNotImplicitlyScopeWrites() async throws {
    try await withMemory { memory in
        let start = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_start", arguments: [:]),
            memory: memory
        )
        #expect(start.isError != true)
        let started = try parseJSONText(in: start)
        let sessionID = try requireString(started, key: "session_id")

        let globalWrite = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: ["content": "GLOBAL_IMPLICIT_SCOPE_GUARD"]
            ),
            memory: memory
        )
        #expect(globalWrite.isError != true)

        let scopedWrite = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": "SESSION_EXPLICIT_SCOPE_GUARD",
                    "session_id": .string(sessionID),
                ]
            ),
            memory: memory
        )
        #expect(scopedWrite.isError != true)

        _ = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory
        )

        let scopedSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: [
                    "query": "GLOBAL_IMPLICIT_SCOPE_GUARD",
                    "mode": "text",
                    "topK": 10,
                    "session_id": .string(sessionID),
                ]
            ),
            memory: memory
        )
        #expect(scopedSearch.isError != true)
        #expect(!firstText(in: scopedSearch).contains("\"frameId\":1"))

        let unscopedSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "GLOBAL_IMPLICIT_SCOPE_GUARD", "mode": "text", "topK": 10]
            ),
            memory: memory
        )
        #expect(unscopedSearch.isError != true)
        #expect(firstText(in: unscopedSearch).contains("\"frameId\":1"))
    }
}

@Test
func rememberRejectsMetadataSessionID() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": "invalid metadata session id",
                    "metadata": .object(["session_id": .string("not-a-uuid")]),
                ]
            ),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("metadata.session_id"))
    }
}

@Test
func vectorFallbackIsSurfacedInSearchAndStats() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-vector-fallback-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        var seedConfig = OrchestratorConfig.default
        seedConfig.enableVectorSearch = false
        let seeded = try await MemoryOrchestrator(at: url, config: seedConfig)
        try await seeded.remember("VECTOR_FALLBACK_SIGNAL Swift actors")
        try await seeded.flush()
        try await seeded.close()
    }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.queryEmbeddingTimeout = .milliseconds(25)
    config.rag.searchMode = .hybrid(alpha: 0.5)

    let memory = try await MemoryOrchestrator(
        at: url,
        config: config,
        embedder: HangingCountingEmbedder()
    )
    defer { Task { try? await memory.close() } }

    let search = await WaxMCPTools.handleCall(
        params: .init(
            name: "wax_search",
            arguments: ["query": "VECTOR_FALLBACK_SIGNAL", "mode": "hybrid", "topK": 5]
        ),
        memory: memory
    )
    #expect(search.isError != true)
    let payload = try parseJSONResource(in: search, uriSuffix: "/search-summary")
    #expect((payload["requested_mode"] as? String) == "hybrid(alpha=0.500)")
    #expect((payload["effective_mode"] as? String) == "text")
    #expect((payload["query_embedding_state"] as? String) == "timeout")

    let stats = await WaxMCPTools.handleCall(
        params: .init(name: "wax_stats", arguments: [:]),
        memory: memory
    )
    #expect(stats.isError != true)
    let statsJSON = try parseJSONText(in: stats)
    #expect((statsJSON["queryEmbeddingCircuitOpen"] as? Bool) == true)
}

@Test
func invalidSessionIDIsRejected() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "x", "mode": "text", "session_id": "not-a-uuid"]
            ),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("session_id must be a valid UUID"))
    }
}

@Test
func handoffRoundTripAndStatsSessionBlockWork() async throws {
    try await withMemory { memory in
        let start = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_start", arguments: [:]),
            memory: memory
        )
        #expect(start.isError != true)
        let started = try parseJSONText(in: start)
        let sessionID = try requireString(started, key: "session_id")

        let handoff = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_handoff",
                arguments: [
                    "content": "Carry over refactor checkpoints",
                    "session_id": .string(sessionID),
                    "project": "wax",
                    "pending_tasks": ["add graph tests", "measure ranking drift"],
                ]
            ),
            memory: memory
        )
        #expect(handoff.isError != true)

        let latest = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_handoff_latest",
                arguments: ["project": "wax"]
            ),
            memory: memory
        )
        #expect(latest.isError != true)
        let latestJSON = try parseJSONText(in: latest)
        #expect((latestJSON["content"] as? String)?.contains("Carry over refactor checkpoints") == true)

        _ = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory
        )

        let stats = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory
        )
        #expect(stats.isError != true)
        let statsJSON = try parseJSONText(in: stats)
        guard let session = statsJSON["session"] as? [String: Any] else {
            Issue.record("Expected session block in wax_stats response")
            return
        }
        #expect((session["active"] as? Bool) == true)
        #expect((session["session_id"] as? String) == sessionID)
        #expect((session["sessionFrameCount"] as? Int ?? 0) >= 1)
    }
}

@Test
func graphToolsRoundTripWorks() async throws {
    try await withMemory { memory in
        let upsert = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_upsert",
                arguments: [
                    "key": "agent:codex",
                    "kind": "agent",
                    "aliases": ["codex", "assistant"],
                ]
            ),
            memory: memory
        )
        #expect(upsert.isError != true)
        let upsertJSON = try parseJSONText(in: upsert)
        #expect((upsertJSON["entity_id"] as? Int ?? 0) > 0)

        let assert = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "learned_behavior",
                    "object": "Prefer focused patches",
                ]
            ),
            memory: memory
        )
        #expect(assert.isError != true)
        let asserted = try parseJSONText(in: assert)
        let factID = try requireInt(asserted, key: "fact_id")

        let factsBeforeRetract = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: ["subject": "agent:codex", "predicate": "learned_behavior", "limit": 20]
            ),
            memory: memory
        )
        #expect(factsBeforeRetract.isError != true)
        #expect(firstText(in: factsBeforeRetract).contains("Prefer focused patches"))

        let retract = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_retract",
                arguments: ["fact_id": .int(factID)]
            ),
            memory: memory
        )
        #expect(retract.isError != true)

        let factsAfterRetract = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: ["subject": "agent:codex", "predicate": "learned_behavior", "limit": 20]
            ),
            memory: memory
        )
        #expect(factsAfterRetract.isError != true)
        #expect(!firstText(in: factsAfterRetract).contains("Prefer focused patches"))

        let resolve = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_resolve",
                arguments: ["alias": "codex", "limit": 5]
            ),
            memory: memory
        )
        #expect(resolve.isError != true)
        #expect(firstText(in: resolve).contains("agent:codex"))
    }
}

@Test
func licenseValidatorRejectsInvalidFormat() {
    do {
        try LicenseValidator.validate(key: "bad-key")
        #expect(Bool(false))
    } catch let error as LicenseValidator.ValidationError {
        #expect(error == .invalidLicenseKey)
    } catch {
        #expect(Bool(false))
    }
}

@Test
func licenseValidatorTrialPassAndExpiration() throws {
    let originalDefaults = LicenseValidator.trialDefaults
    let originalKey = LicenseValidator.firstLaunchKey
    let originalKeychain = LicenseValidator.keychainEnabled

    let suiteName = "wax-mcp-tests-\(UUID().uuidString)"
    guard let suite = UserDefaults(suiteName: suiteName) else {
        throw NSError(domain: "WaxMCPServerTests", code: 1, userInfo: nil)
    }

    LicenseValidator.trialDefaults = suite
    LicenseValidator.firstLaunchKey = "wax_first_launch_test"
    LicenseValidator.keychainEnabled = false

    defer {
        LicenseValidator.trialDefaults = originalDefaults
        LicenseValidator.firstLaunchKey = originalKey
        LicenseValidator.keychainEnabled = originalKeychain
        suite.removePersistentDomain(forName: suiteName)
    }

    try LicenseValidator.validate(key: nil)

    suite.set(
        Date(timeIntervalSinceNow: -(15 * 24 * 60 * 60)),
        forKey: LicenseValidator.firstLaunchKey
    )

    do {
        try LicenseValidator.validate(key: nil)
        #expect(Bool(false))
    } catch let error as LicenseValidator.ValidationError {
        #expect(error == .trialExpired)
    }
}

private func withMemory(
    _ body: @Sendable (MemoryOrchestrator) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-tests-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = true
    config.chunking = .tokenCount(targetTokens: 16, overlapTokens: 2)
    config.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .textOnly
    )

    let memory = try await MemoryOrchestrator(at: url, config: config)
    var deferredError: Error?

    do {
        try await body(memory)
    } catch {
        deferredError = error
    }

    do {
        try await memory.close()
    } catch {
        if deferredError == nil {
            deferredError = error
        }
    }

    if let deferredError {
        throw deferredError
    }
}

private func firstText(in result: CallTool.Result) -> String {
    for content in result.content {
        if case .text(let text) = content {
            return text
        }
    }
    return ""
}

private func parseJSONText(in result: CallTool.Result) throws -> [String: Any] {
    let text = firstText(in: result)
    guard let data = text.data(using: .utf8) else {
        throw NSError(domain: "WaxMCPServerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 result"])
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dict = object as? [String: Any] else {
        throw NSError(domain: "WaxMCPServerTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Result is not a JSON object"])
    }
    return dict
}

private func parseJSONResource(in result: CallTool.Result, uriSuffix: String) throws -> [String: Any] {
    for content in result.content {
        if case .resource(let resource, _, _) = content,
           resource.uri.hasSuffix(uriSuffix),
           let text = resource.text,
           let data = text.data(using: .utf8) {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else {
                throw NSError(domain: "WaxMCPServerTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Resource is not a JSON object"])
            }
            return dict
        }
    }
    throw NSError(domain: "WaxMCPServerTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing JSON resource with suffix '\(uriSuffix)'"])
}

private func requireString(_ object: [String: Any], key: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
        throw NSError(domain: "WaxMCPServerTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing string key '\(key)'"])
    }
    return value
}

private func requireInt(_ object: [String: Any], key: String) throws -> Int {
    if let value = object[key] as? Int {
        return value
    }
    if let value = object[key] as? NSNumber {
        return value.intValue
    }
    throw NSError(domain: "WaxMCPServerTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing int key '\(key)'"])
}

private actor HangingCountingEmbedder: EmbeddingProvider {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Test",
        model: "Hanging",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        try await Task.sleep(for: .seconds(60))
        return [1.0, 0.0]
    }
}
#else
@Test
func mcpServerTestsRequireTrait() {
    #expect(Bool(true))
}
#endif
