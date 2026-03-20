import Foundation
import Testing

#if MCPServer
import MCP
@testable import wax_mcp
import Wax
import XCTest

@Test
func toolsListContainsExpectedTools() {
    let names = Set(ToolSchemas.allTools.map(\.name))
    #expect(names.contains("wax_remember"))
    #expect(names.contains("wax_recall"))
    #expect(names.contains("wax_search"))
    #expect(names.contains("wax_corpus_search"))
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
    let requiredTools = ["wax_remember", "wax_recall", "wax_search", "wax_corpus_search", "wax_flush", "wax_stats"]
    for required in requiredTools {
        #expect(uniqueNames.contains(required), "Required tool '\(required)' is missing from schema")
    }

    // Tool inputSchemas must be well-formed objects, and tools with required inputs
    // must preserve those requirements in the published schema.
    let schemas: [(name: String, schema: Value, requiresNonEmptyFields: Bool)] = [
        ("wax_remember", ToolSchemas.waxRemember, true),
        ("wax_recall", ToolSchemas.waxRecall, true),
        ("wax_search", ToolSchemas.waxSearch, true),
        ("wax_corpus_search", ToolSchemas.waxCorpusSearch, true),
        ("wax_flush", ToolSchemas.waxFlush, false),
        ("wax_stats", ToolSchemas.waxStats, false),
        ("wax_session_start", ToolSchemas.waxSessionStart, false),
        ("wax_session_end", ToolSchemas.waxSessionEnd, false),
        ("wax_handoff", ToolSchemas.waxHandoff, true),
        ("wax_handoff_latest", ToolSchemas.waxHandoffLatest, false),
        ("wax_entity_upsert", ToolSchemas.waxEntityUpsert, true),
        ("wax_fact_assert", ToolSchemas.waxFactAssert, true),
        ("wax_fact_retract", ToolSchemas.waxFactRetract, true),
        ("wax_facts_query", ToolSchemas.waxFactsQuery, false),
        ("wax_entity_resolve", ToolSchemas.waxEntityResolve, true),
    ]
    for (toolName, schema, requiresNonEmptyFields) in schemas {
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
            if requiresNonEmptyFields {
                #expect(!required.isEmpty, "Schema for '\(toolName)' has no required fields")
            }
        } else {
            Issue.record("Schema for '\(toolName)' is missing 'required' array")
        }
    }
}

@Test
func recallSchemaExposesLegacyTopKAlias() {
    guard let obj = ToolSchemas.waxRecall.objectValue,
          case .object(let properties) = obj["properties"]
    else {
        Issue.record("wax_recall schema is missing object properties")
        return
    }

    #expect(properties["search_top_k"] != nil)
    #expect(properties["topK"] != nil)
}

@Test
func toolsRejectUnknownTopLevelArguments() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_recall",
                arguments: [
                    "query": .string("actors"),
                    "limit": .int(3),
                    "unexpected": .string("boom"),
                ]
            ),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("unsupported argument"))
    }
}

@Test
func corpusSearchRejectsUnknownTopLevelArguments() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_corpus_search",
                arguments: [
                    "query": .string("actors"),
                    "sessionsDir": .string("/tmp/typo"),
                ]
            ),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("unsupported argument"))
    }
}

@Test
func factAssertRejectsMixedTypedObjectKeys() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "object": .object([
                        "entity": .string("project:wax"),
                        "time_ms": .int(123),
                    ]),
                ]
            ),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("typed object"))
    }
}

@Test
func sessionEndRequiresSessionIDWhenMultipleSessionsActive() async throws {
    try await withMemory { memory in
        let first = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_start", arguments: [:]),
            memory: memory
        )
        let second = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_start", arguments: [:]),
            memory: memory
        )
        #expect(first.isError != true)
        #expect(second.isError != true)

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_end", arguments: [:]),
            memory: memory
        )
        #expect(end.isError == true)
        #expect(firstText(in: end).contains("session_id is required"))
    }
}

@Test
func waxMCPProcessRespondsAfterImmediateEOF() async throws {
    let harness = try MCPServerProcessHarness()
    try harness.start()
    defer { harness.terminateIfNeeded() }

    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "wax-mcp-eof-test", "version": "1.0"],
        ],
    ])
    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": [:],
    ])
    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
        "params": [:],
    ])
    try harness.closeInput()

    let initialize = try await harness.waitForResponseLine(id: 1)
    let toolsList = try await harness.waitForResponseLine(id: 2)

    #expect(initialize.contains(#""protocolVersion":"2024-11-05""#))
    #expect(toolsList.contains(#""name":"wax_remember""#))
    #expect(try await harness.waitForExit() == EXIT_SUCCESS)
}

@Test
func waxMCPProcessFlushesPendingWritesOnSIGTERM() async throws {
    let harness = try MCPServerProcessHarness()
    try harness.start()
    defer { harness.terminateIfNeeded() }

    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "wax-mcp-sigterm-test", "version": "1.0"],
        ],
    ])
    _ = try await harness.waitForResponseLine(id: 1)
    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": [:],
    ])

    let marker = "waxmcp-sigterm-\(UUID().uuidString)"
    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": [
            "name": "wax_remember",
            "arguments": [
                "content": marker,
                "commit": false,
            ],
        ],
    ])
    let remember = try await harness.waitForResponseLine(id: 2)
    let rememberJSON = try parseToolTextJSON(fromResponseLine: remember)
    #expect((rememberJSON["committed"] as? Bool) == false)

    try harness.sendSignal(SIGTERM)
    #expect(try await harness.waitForExit() == EXIT_SUCCESS)

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    let reopened = try await MemoryOrchestrator(at: harness.storeURL, config: config)
    defer { Task { try? await reopened.close() } }
    let context = try await reopened.recall(query: marker)
    #expect(context.items.contains { $0.text.contains(marker) })
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
func corpusSearchBuildsAcrossSessionStoresAndReturnsProvenance() async throws {
    try await withMemory { memory in
        try await withTemporaryDirectory { root in
            let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

            let sourceA = sessionsDir.appendingPathComponent("session-a.wax")
            let sourceB = sessionsDir.appendingPathComponent("session-b.wax")
            let corpus = root.appendingPathComponent("corpus.wax")

            try await writeSessionStore(
                at: sourceA,
                documents: [("Apollo guidance session with thruster calibration notes.", ["session_id": "session-a"])]
            )
            try await writeSessionStore(
                at: sourceB,
                documents: [("Zephyr retrieval session covering lunar habitat logistics.", ["session_id": "session-b"])]
            )

            let result = await WaxMCPTools.handleCall(
                params: .init(
                    name: "wax_corpus_search",
                    arguments: [
                        "query": .string("thruster calibration"),
                        "sessions_dir": .string(sessionsDir.path),
                        "corpus_store_path": .string(corpus.path),
                        "mode": .string("text"),
                        "topK": .int(5),
                        "rebuild": .bool(true),
                    ]
                ),
                memory: memory,
                noEmbedder: true
            )

            #expect(result.isError != true)
            #expect(firstText(in: result).contains("session-a.wax"))

            let resource = try parseJSONResource(in: result, uriSuffix: "/corpus-search-summary")
            let build = try requireObject(resource, key: "build")
            #expect((build["performed"] as? Bool) == true)
            #expect((build["stores_discovered"] as? Int) == 2)
            #expect((build["documents_indexed"] as? Int) == 2)

            let results = try requireArray(resource, key: "results")
            let first = try requireObject(results[0])
            let metadata = try requireObject(first, key: "metadata")
            #expect((metadata[CorpusMetadataKeys.sourceStorePath] as? String) == sourceA.path)
            #expect((metadata[CorpusMetadataKeys.sourceStoreName] as? String) == "session-a.wax")
            #expect((metadata["session_id"] as? String) == "session-a")
        }
    }
}

@Test
func corpusSearchRejectsInvalidTopK() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_corpus_search",
                arguments: [
                    "query": .string("anything"),
                    "topK": .int(0),
                ]
            ),
            memory: memory,
            noEmbedder: true
        )

        #expect(result.isError == true)
        #expect(firstText(in: result).contains("topK must be between 1 and"))
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

        let recallBeforeFlush = await WaxMCPTools.handleCall(
            params: .init(name: "wax_recall", arguments: ["query": .string(queryToken), "limit": .int(5)]),
            memory: memory
        )
        #expect(recallBeforeFlush.isError == true)
        #expect(firstText(in: recallBeforeFlush).contains("wax_flush"))

        let searchBeforeFlush = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": .string(queryToken), "mode": "text", "topK": .int(5)]
            ),
            memory: memory
        )
        #expect(searchBeforeFlush.isError == true)
        #expect(firstText(in: searchBeforeFlush).contains("wax_flush"))

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
func endedSessionIDIsRejectedOnLaterScopedCalls() async throws {
    try await withMemory { memory in
        let start = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_start", arguments: [:]),
            memory: memory
        )
        #expect(start.isError != true)
        let started = try parseJSONText(in: start)
        let sessionID = try requireString(started, key: "session_id")

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_end", arguments: ["session_id": .string(sessionID)]),
            memory: memory
        )
        #expect(end.isError != true)

        let remember = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": "should fail after end",
                    "session_id": .string(sessionID),
                ]
            ),
            memory: memory
        )
        #expect(remember.isError == true)
        #expect(firstText(in: remember).contains("session_id is not active"))

        let search = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: [
                    "query": "should fail after end",
                    "mode": "text",
                    "topK": 5,
                    "session_id": .string(sessionID),
                ]
            ),
            memory: memory
        )
        #expect(search.isError == true)
        #expect(firstText(in: search).contains("session_id is not active"))
    }
}

@Test
func sessionEndReportsRemainingActiveSessions() async throws {
    try await withMemory { memory in
        let startA = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_start", arguments: [:]),
            memory: memory
        )
        #expect(startA.isError != true)
        let sessionA = try requireString(try parseJSONText(in: startA), key: "session_id")

        let startB = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_start", arguments: [:]),
            memory: memory
        )
        #expect(startB.isError != true)
        let sessionB = try requireString(try parseJSONText(in: startB), key: "session_id")

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_end", arguments: ["session_id": .string(sessionA)]),
            memory: memory
        )
        #expect(end.isError != true)
        let ended = try parseJSONText(in: end)
        #expect((ended["session_id"] as? String) == sessionA)
        #expect((ended["active"] as? Bool) == true)

        let stats = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory
        )
        #expect(stats.isError != true)
        let statsJSON = try parseJSONText(in: stats)
        let session = statsJSON["session"] as? [String: Any]
        #expect((session?["activeSessionCount"] as? Int) == 1)
        #expect((session?["activeSessionIds"] as? [String]) == [sessionB])
    }
}

@Test
func statsReportQueryEmbeddingAvailableWithoutIdentityMetadata() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-identityless-embedder-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.queryEmbeddingTimeout = .seconds(1)

    let memory = try await MemoryOrchestrator(
        at: url,
        config: config,
        embedder: IdentitylessEmbedder()
    )
    defer { Task { try? await memory.close() } }

    let stats = await WaxMCPTools.handleCall(
        params: .init(name: "wax_stats", arguments: [:]),
        memory: memory
    )
    #expect(stats.isError != true)
    let statsJSON = try parseJSONText(in: stats)
    #expect((statsJSON["queryEmbeddingAvailable"] as? Bool) == true)
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

private func withTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-corpus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try await body(url)
}

private func writeSessionStore(
    at url: URL,
    documents: [(String, [String: String])]
) async throws {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = false
    config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)
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
        for (text, metadata) in documents {
            try await memory.remember(text, metadata: metadata)
        }
        try await memory.flush()
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

private func withVectorMemory(
    _ body: @Sendable (MemoryOrchestrator) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-vector-tests-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.enableTextSearch = true
    config.enableStructuredMemory = false
    config.ingestEmbeddingTimeout = .seconds(5)
    config.queryEmbeddingTimeout = .seconds(5)
    config.chunking = .tokenCount(targetTokens: 200, overlapTokens: 20)
    config.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .hybrid(alpha: 0.5)
    )

    let embedder = MCPTestDeterministicEmbedder()
    let memory = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
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

@Test
func vectorSearchRememberFlushRecallHappyPath() async throws {
    try await withVectorMemory { memory in
        let remember = await WaxMCPTools.handleCall(
            params: .init(name: "wax_remember", arguments: [
                "content": .string("Swift actors provide data isolation through actor-isolated state."),
                "commit": .bool(true),
            ]),
            memory: memory
        )
        #expect(remember.isError != true)
        let rememberJSON = try parseJSONText(in: remember)
        #expect((rememberJSON["status"] as? String) == "ok")
        let framesAdded = rememberJSON["framesAdded"] as? Int ?? 0
        #expect(framesAdded > 0)

        let recall = await WaxMCPTools.handleCall(
            params: .init(name: "wax_recall", arguments: [
                "query": .string("actors"),
            ]),
            memory: memory
        )
        #expect(recall.isError != true)
        let recallText = firstText(in: recall)
        #expect(recallText.contains("Results:"))

        let search = await WaxMCPTools.handleCall(
            params: .init(name: "wax_search", arguments: [
                "query": .string("actors"),
                "mode": .string("hybrid"),
            ]),
            memory: memory
        )
        #expect(search.isError != true)
    }
}

@Test
func vectorSearchRememberTimesOutWithHangingEmbedder() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-hang-remember-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.ingestEmbeddingTimeout = .milliseconds(100)

    let memory = try await MemoryOrchestrator(
        at: url,
        config: config,
        embedder: HangingCountingEmbedder()
    )
    defer { Task { try? await memory.close() } }

    let result = await WaxMCPTools.handleCall(
        params: .init(name: "wax_remember", arguments: [
            "content": .string("This should time out."),
        ]),
        memory: memory
    )
    #expect(result.isError == true)
    let text = firstText(in: result)
    #expect(text.localizedCaseInsensitiveContains("timeout") || text.localizedCaseInsensitiveContains("timed out"))
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

private func parseToolTextJSON(fromResponseLine line: String) throws -> [String: Any] {
    guard let data = line.data(using: .utf8) else {
        throw NSError(domain: "WaxMCPServerTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 response line"])
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dict = object as? [String: Any],
          let result = dict["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]],
          let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
          let textData = text.data(using: .utf8)
    else {
        throw NSError(domain: "WaxMCPServerTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "Missing tool text payload"])
    }

    let textObject = try JSONSerialization.jsonObject(with: textData)
    guard let textDict = textObject as? [String: Any] else {
        throw NSError(domain: "WaxMCPServerTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "Tool text payload is not a JSON object"])
    }
    return textDict
}

private func requireString(_ object: [String: Any], key: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
        throw NSError(domain: "WaxMCPServerTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing string key '\(key)'"])
    }
    return value
}

private func requireObject(_ object: [String: Any], key: String) throws -> [String: Any] {
    guard let nested = object[key] as? [String: Any] else {
        throw NSError(
            domain: "WaxMCPServerTests",
            code: 20,
            userInfo: [NSLocalizedDescriptionKey: "Missing object value for key '\(key)'"]
        )
    }
    return nested
}

private func requireObject(_ value: Any) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
        throw NSError(
            domain: "WaxMCPServerTests",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "Value is not a JSON object"]
        )
    }
    return object
}

private func requireArray(_ object: [String: Any], key: String) throws -> [Any] {
    guard let array = object[key] as? [Any] else {
        throw NSError(
            domain: "WaxMCPServerTests",
            code: 22,
            userInfo: [NSLocalizedDescriptionKey: "Missing array value for key '\(key)'"]
        )
    }
    return array
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

private actor IdentitylessEmbedder: EmbeddingProvider {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = nil

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [1.0, 0.0]
    }
}

private struct MCPTestDeterministicEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "MCPTest",
        model: "Deterministic",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        let norm = sqrt(a * a + b * b)
        guard norm > 0 else { return [1, 0] }
        return [a / norm, b / norm]
    }
}

private final class MCPServerProcessHarness: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdoutLines: [String] = []
    private var stdoutPending = Data()
    private var stderrPending = Data()
    private var stderrLines: [String] = []

    let storeURL: URL

    init(useRealEmbedder: Bool = false) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        self.storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-process-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        process.executableURL = try Self.waxMCPBinaryURL(packageRoot: root)
        var args = ["--store-path", storeURL.path]
        if !useRealEmbedder {
            args.append("--no-embedder")
        }
        process.arguments = args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.appendOutput(data, toStdout: true)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.appendOutput(data, toStdout: false)
        }
        try process.run()
    }

    func terminateIfNeeded() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdinPipe.fileHandleForWriting.close()
    }

    func sendJSONLine(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    func closeInput() throws {
        try stdinPipe.fileHandleForWriting.close()
    }

    func sendSignal(_ signal: Int32) throws {
        guard process.processIdentifier > 0 else {
            throw NSError(domain: "MCPServerProcessHarness", code: 1)
        }
        Darwin.kill(process.processIdentifier, signal)
    }

    func waitForResponseLine(id: Int, timeout: TimeInterval = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let needle = #""id":\#(id)"#
        while Date() < deadline {
            if let line = withLocked({ stdoutLines.first(where: { $0.contains(needle) }) }) {
                return line
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stderr = withLocked { stderrLines.joined(separator: "\n") }
        throw NSError(
            domain: "MCPServerProcessHarness",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for response id \(id). stderr=\(stderr)"]
        )
    }

    func waitForExit(timeout: TimeInterval = 5) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                drainPipes()
                return process.terminationStatus
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "MCPServerProcessHarness", code: 3)
    }

    private func drainPipes() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let remaining = try? stdoutPipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
            appendOutput(remaining, toStdout: true)
        }
        if let remaining = try? stderrPipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
            appendOutput(remaining, toStdout: false)
        }
    }

    private func appendOutput(_ data: Data, toStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if toStdout {
            stdoutPending.append(data)
            Self.extractLines(from: &stdoutPending, into: &stdoutLines)
        } else {
            stderrPending.append(data)
            Self.extractLines(from: &stderrPending, into: &stderrLines)
        }
    }

    private func withLocked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func extractLines(from pending: inout Data, into target: inout [String]) {
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[..<newline]
            pending = pending[(newline + 1)...]
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            target.append(line)
        }
    }

    private static func waxMCPBinaryURL(packageRoot: URL) throws -> URL {
        let bundleDebugDir = Bundle(for: XCTestCase.self).bundleURL.deletingLastPathComponent()
        let candidates = [
            bundleDebugDir.appendingPathComponent("wax-mcp"),
            packageRoot.appendingPathComponent(".build/debug/wax-mcp"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/wax-mcp"),
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        let attempted = candidates.map(\.path).joined(separator: "\n")
        throw NSError(
            domain: "MCPServerProcessHarness",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not find wax-mcp binary. Tried:\n\(attempted)"]
        )
    }

    func stderrSnapshot() -> String {
        withLocked { stderrLines.joined(separator: "\n") }
    }
}

@Test(.timeLimit(.minutes(2)))
func waxMCPProcessRememberWithRealCoreMLEmbedder() async throws {
    let harness = try MCPServerProcessHarness(useRealEmbedder: true)
    try harness.start()
    defer { harness.terminateIfNeeded() }

    // Initialize — allow up to 60s for CoreML model load + prewarm
    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "wax-mcp-coreml-test", "version": "1.0"],
        ],
    ])
    let initResp = try await harness.waitForResponseLine(id: 1, timeout: 60)
    #expect(initResp.contains(#""protocolVersion":"2024-11-05""#))

    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": [:],
    ])

    // 200+ word content → forces 256-token bucket (NOT prewarmed)
    let longContent = """
    The architecture of modern distributed systems requires careful consideration \
    of consistency models, partition tolerance, and availability guarantees as \
    described by the CAP theorem. When designing microservices that communicate \
    via message queues and event-driven architectures, developers must account for \
    eventual consistency, idempotent message processing, and proper dead-letter \
    queue handling. The Swift programming language provides excellent support for \
    building concurrent applications through its actor model, which isolates \
    mutable state and prevents data races at compile time. Combined with async/await \
    syntax and structured concurrency via task groups, Swift enables developers to \
    write safe, performant server-side applications. Core ML on Apple platforms \
    offers on-device machine learning inference with support for neural engine \
    acceleration, but careful attention must be paid to model compilation, \
    sequence length bucketing, and thread pool management to avoid performance \
    bottlenecks. The MiniLM model produces 384-dimensional dense embeddings \
    suitable for semantic search and retrieval-augmented generation workflows.
    """

    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": [
            "name": "wax_remember",
            "arguments": ["content": longContent],
        ],
    ])

    let rememberResp = try await harness.waitForResponseLine(id: 2, timeout: 60)
    let rememberJSON = try parseToolTextJSON(fromResponseLine: rememberResp)
    #expect((rememberJSON["committed"] as? Bool) == true)

    // Recall with vector search to exercise the query embedding path
    try harness.sendJSONLine([
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": [
            "name": "wax_recall",
            "arguments": ["query": "Swift concurrency", "limit": 3],
        ],
    ])
    let recallResp = try await harness.waitForResponseLine(id: 3, timeout: 30)
    #expect(recallResp.contains("result"))

    try harness.closeInput()
    #expect(try await harness.waitForExit(timeout: 10) == EXIT_SUCCESS)
}

#else
@Test
func mcpServerTestsRequireTrait() {
    #expect(Bool(true))
}
#endif
