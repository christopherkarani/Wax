import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if MCPServer
import MCP
@testable import wax_mcp
import Wax
import XCTest

private func withAgentBrokerService<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-test-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let result = try await body(service, sessionRootURL)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

@Test
func brokerRejectsInvalidEmbedderChoice() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-invalid-embedder-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    do {
        let service = try await AgentBrokerService(
            storePath: storeURL.path,
            sessionRootPath: sessionRootURL.path,
            noEmbedder: false,
            embedderChoice: "definitelyInvalid",
            requireVector: false
        )
        try await service.close()
        Issue.record("invalid embedder choice should fail instead of falling back to MiniLM")
    } catch {
        #expect(error.localizedDescription.contains("Invalid embedder choice"))
        #expect(error.localizedDescription.contains("minilm"))
        #expect(error.localizedDescription.contains("arctic"))
    }
}

@Test
func toolsListContainsExpectedTools() {
    let names = Set(ToolSchemas.allTools.map(\.name))
    #expect(names.contains("memory_append"))
    #expect(names.contains("memory_search"))
    #expect(names.contains("memory_get"))
    #expect(names.contains("remember"))
    #expect(names.contains("recall"))
    #expect(names.contains("search"))
    #expect(names.contains("session_synthesize"))
    #expect(names.contains("memory_promote"))
    #expect(names.contains("promote"))
    #expect(names.contains("memory_health"))
    #expect(names.contains("knowledge_capture"))
    #expect(names.contains("corpus_search"))
    #expect(!names.contains("flush"))
    #expect(names.contains("stats"))
    #expect(names.contains("session_start"))
    #expect(names.contains("session_resume"))
    #expect(names.contains("session_end"))
    #expect(names.contains("handoff"))
    #expect(names.contains("handoff_latest"))
    #expect(names.contains("compact_context"))
    #expect(names.contains("markdown_export"))
    #expect(names.contains("markdown_sync"))
    #expect(names.contains("entity_upsert"))
    #expect(names.contains("fact_assert"))
    #expect(names.contains("fact_retract"))
    #expect(names.contains("facts_query"))
    #expect(names.contains("entity_resolve"))
    // Verify no duplicate tool names
    #expect(names.count == ToolSchemas.allTools.count)
}

@Test
func toolsListHonorsStructuredMemoryFlag() {
    let withStructuredMemory = Set(ToolSchemas.tools(structuredMemoryEnabled: true).map(\.name))
    let withoutStructuredMemory = Set(ToolSchemas.tools(structuredMemoryEnabled: false).map(\.name))
    #expect(withStructuredMemory.contains("facts_query"))
    #expect(!withoutStructuredMemory.contains("facts_query"))
    #expect(withStructuredMemory.contains("entity_upsert"))
    #expect(!withoutStructuredMemory.contains("entity_upsert"))
    #expect(!withoutStructuredMemory.contains("fact_assert"))
    #expect(!withoutStructuredMemory.contains("knowledge_capture"))
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
    let requiredTools = ["memory_append", "memory_search", "memory_get", "remember", "recall", "search", "session_synthesize", "memory_promote", "promote", "memory_health", "knowledge_capture", "corpus_search", "stats", "session_resume", "compact_context", "markdown_export", "markdown_sync"]
    for required in requiredTools {
        #expect(uniqueNames.contains(required), "Required tool '\(required)' is missing from schema")
    }

    // Tool inputSchemas must be well-formed objects, and tools with required inputs
    // must preserve those requirements in the published schema.
    let schemas: [(name: String, schema: Value, requiresNonEmptyFields: Bool)] = [
        ("memory_append", ToolSchemas.waxMemoryAppend, true),
        ("memory_search", ToolSchemas.waxMemorySearch, true),
        ("memory_get", ToolSchemas.waxMemoryGet, true),
        ("remember", ToolSchemas.waxRemember, true),
        ("recall", ToolSchemas.waxRecall, true),
        ("search", ToolSchemas.waxSearch, true),
        ("session_synthesize", ToolSchemas.waxSessionSynthesize, false),
        ("memory_promote", ToolSchemas.waxMemoryPromote, false),
        ("promote", ToolSchemas.waxPromote, false),
        ("memory_health", ToolSchemas.waxMemoryHealth, false),
        ("knowledge_capture", ToolSchemas.waxKnowledgeCapture, true),
        ("corpus_search", ToolSchemas.waxCorpusSearch, true),
        ("stats", ToolSchemas.waxStats, false),
        ("session_start", ToolSchemas.waxSessionStart, false),
        ("session_resume", ToolSchemas.waxSessionResume, false),
        ("session_end", ToolSchemas.waxSessionEnd, false),
        ("handoff", ToolSchemas.waxHandoff, true),
        ("handoff_latest", ToolSchemas.waxHandoffLatest, false),
        ("compact_context", ToolSchemas.waxCompactContext, true),
        ("markdown_export", ToolSchemas.waxMarkdownExport, true),
        ("markdown_sync", ToolSchemas.waxMarkdownSync, true),
        ("entity_upsert", ToolSchemas.waxEntityUpsert, true),
        ("fact_assert", ToolSchemas.waxFactAssert, true),
        ("fact_retract", ToolSchemas.waxFactRetract, true),
        ("facts_query", ToolSchemas.waxFactsQuery, false),
        ("entity_resolve", ToolSchemas.waxEntityResolve, true),
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
        Issue.record("recall schema is missing object properties")
        return
    }

    #expect(properties["search_top_k"] != nil)
    #expect(properties["topK"] != nil)
}

@Test
func schemasExposeVectorSearchMode() {
    let schemas = [
        ToolSchemas.waxRecall,
        ToolSchemas.waxSearch,
        ToolSchemas.waxMemorySearch,
        ToolSchemas.waxCorpusSearch,
        ToolSchemas.waxCompactContext,
    ]

    for schema in schemas {
        #expect(schemaEnum(schema, property: "mode") == ["text", "vector", "hybrid"])
    }
}

@Test
func factAssertSchemaExposesVersionRelation() {
    #expect(schemaEnum(ToolSchemas.waxFactAssert, property: "relation") == ["sets", "updates", "extends", "retracts"])
}

@Test
func toolsRejectUnknownTopLevelArguments() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
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
func brokerRejectsUnknownTopLevelArguments() async throws {
    try await withAgentBrokerService { service, _ in
        let response = await service.handle(
            AgentBrokerRequest(
                command: "recall",
                arguments: [
                    "query": .string("actors"),
                    "limit": .int(3),
                    "unexpected": .string("boom"),
                ]
            )
        )

        #expect(response.ok == false)
        #expect(response.error?.contains("unsupported argument") == true)
        #expect(response.error?.contains("unexpected") == true)
    }
}

@Test
func promotionMaxCandidatesAreBounded() async throws {
    setenv("WAX_OPENCLAW_PROMOTION_MAX_CANDIDATES", "1000000", 1)
    defer { unsetenv("WAX_OPENCLAW_PROMOTION_MAX_CANDIDATES") }

    #expect(BrokerPromotionSettings.fromEnvironment().maxCandidates == 12)
    #expect(schemaMaximum(ToolSchemas.waxSessionSynthesize, property: "max_candidates") == 12)
    #expect(schemaMaximum(ToolSchemas.waxMemoryPromote, property: "max_candidates") == 12)

    try await withAgentBrokerService { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        let startedPayload = try #require(started.payload?.objectValue)
        let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)

        for index in 0..<20 {
            let append = await service.handle(.init(
                command: "memory_append",
                arguments: [
                    "content": .string("Decision: bounded promotion candidate \(index) should stay within the server maximum."),
                    "session_id": .string(sessionIDString),
                ]
            ))
            #expect(append.ok == true)
        }

        let synthesize = await service.handle(
            AgentBrokerRequest(
                command: "session_synthesize",
                arguments: [
                    "session_id": .string(sessionIDString),
                    "max_candidates": .int(1_000_000),
                ]
            )
        )
        #expect(synthesize.ok == true)
        let payload = try #require(synthesize.payload?.objectValue)
        let candidates = try #require(payload["durable_candidates"]?.arrayValue)
        #expect(candidates.count <= 12)
    }
}

@Test
func corpusSearchRejectsUnknownTopLevelArguments() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "corpus_search",
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
                name: "fact_assert",
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
func factAssertAcceptsPublishedGenericTypedObjects() async throws {
    try await withMemory { memory in
        let encoded = Data("opaque bytes".utf8).base64EncodedString()
        let cases: [(predicate: String, object: Value, expected: String)] = [
            (
                "owner",
                .object(["type": .string("entity"), "value": .string("agent:codex")]),
                #""entity":"agent:codex""#
            ),
            (
                "seen_at",
                .object(["type": .string("time_ms"), "value": .int(123)]),
                #""time_ms":123"#
            ),
            (
                "payload",
                .object(["type": .string("data_base64"), "value": .string(encoded)]),
                #""data_base64":"\#(encoded)""#
            ),
        ]

        for testCase in cases {
            let result = await WaxMCPTools.handleCall(
                params: .init(
                    name: "fact_assert",
                    arguments: [
                        "subject": .string("project:wax"),
                        "predicate": .string(testCase.predicate),
                        "object": testCase.object,
                    ]
                ),
                memory: memory
            )
            #expect(result.isError != true)

            let query = await WaxMCPTools.handleCall(
                params: .init(
                    name: "facts_query",
                    arguments: [
                        "subject": .string("project:wax"),
                        "predicate": .string(testCase.predicate),
                    ]
                ),
                memory: memory
            )
            #expect(query.isError != true)
            #expect(firstText(in: query).contains(testCase.expected))
        }
    }
}

@Test
func brokerFactAssertAcceptsPublishedGenericTypedObjects() async throws {
    try await withAgentBrokerService { service, _ in
        let encoded = Data("opaque bytes".utf8).base64EncodedString()
        let cases: [(predicate: String, object: AgentBrokerValue, expectedKey: String, expectedValue: AgentBrokerValue)] = [
            (
                "owner",
                .object(["type": .string("entity"), "value": .string("agent:codex")]),
                "entity",
                .string("agent:codex")
            ),
            (
                "seen_at",
                .object(["type": .string("time_ms"), "value": .int(123)]),
                "time_ms",
                .int(123)
            ),
            (
                "payload",
                .object(["type": .string("data_base64"), "value": .string(encoded)]),
                "data_base64",
                .string(encoded)
            ),
        ]

        for testCase in cases {
            let asserted = await service.handle(.init(
                command: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string(testCase.predicate),
                    "object": testCase.object,
                ]
            ))
            #expect(asserted.ok == true)

            let queried = await service.handle(.init(
                command: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string(testCase.predicate),
                ]
            ))
            #expect(queried.ok == true)
            let payload = try #require(queried.payload?.objectValue)
            let facts = try #require(payload["hits"]?.arrayValue)
            let firstFact = try #require(facts.first?.objectValue)
            #expect(firstFact["object"]?.objectValue?[testCase.expectedKey] == testCase.expectedValue)
        }
    }
}

@Test
func temporalFactArgumentsAreHonoredByPublishedTools() async throws {
    try await withMemory { memory in
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let asserted = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "object": .string("temporal"),
                    "valid_from": .int(Int(nowMs)),
                    "valid_to": .int(Int(nowMs + 100)),
                ]
            ),
            memory: memory
        )
        #expect(asserted.isError != true)

        let insideValidWindow = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "as_of": .int(Int(nowMs + 50)),
                ]
            ),
            memory: memory
        )
        #expect(insideValidWindow.isError != true)
        #expect(firstText(in: insideValidWindow).contains("temporal"))

        let outsideValidWindow = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "as_of": .int(Int(nowMs + 150)),
                ]
            ),
            memory: memory
        )
        #expect(outsideValidWindow.isError != true)
        #expect(!firstText(in: outsideValidWindow).contains("temporal"))

        let retractable = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("retractable"),
                    "object": .string("temporal retraction"),
                    "valid_from": .int(Int(nowMs)),
                ]
            ),
            memory: memory
        )
        #expect(retractable.isError != true)
        let retractableJSON = try parseJSONText(in: retractable)
        let factID = try requireInt(retractableJSON, key: "fact_id")

        let retract = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_retract",
                arguments: [
                    "fact_id": .int(factID),
                    "at_ms": .int(Int(nowMs + 200)),
                ]
            ),
            memory: memory
        )
        #expect(retract.isError != true)

        let beforeRetractionTime = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("retractable"),
                    "as_of": .int(Int(nowMs + 150)),
                ]
            ),
            memory: memory
        )
        #expect(beforeRetractionTime.isError != true)
        #expect(firstText(in: beforeRetractionTime).contains("temporal retraction"))

        let afterRetractionTime = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("retractable"),
                    "as_of": .int(Int(nowMs + 250)),
                ]
            ),
            memory: memory
        )
        #expect(afterRetractionTime.isError != true)
        #expect(!firstText(in: afterRetractionTime).contains("temporal retraction"))
    }
}

@Test
func httpRequestBodyLimitRejectsContentLengthAndStreamingOverflow() {
    #expect(HTTPRequestBodyLimit.exceedsLimit(
        currentBytes: 0,
        incomingBytes: 0,
        contentLength: 1_049,
        maxBytes: 1_048
    ))
    #expect(HTTPRequestBodyLimit.exceedsLimit(
        currentBytes: 1_000,
        incomingBytes: 49,
        contentLength: nil,
        maxBytes: 1_048
    ))
    #expect(!HTTPRequestBodyLimit.exceedsLimit(
        currentBytes: 1_000,
        incomingBytes: 48,
        contentLength: nil,
        maxBytes: 1_048
    ))
}

@Test
func openClawPackageDeclaresSDKPeerDependency() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let packageJSONURL = packageRoot
        .appendingPathComponent("Resources/openclaw/wax-memory-plugin/package.json")
    let data = try Data(contentsOf: packageJSONURL)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let peerDependencies = try #require(json["peerDependencies"] as? [String: Any])
    let devDependencies = try #require(json["devDependencies"] as? [String: Any])

    #expect(peerDependencies["openclaw"] as? String == ">=2026.3.24-beta.2")
    #expect(devDependencies["openclaw"] as? String == ">=2026.3.24-beta.2")
}

@Test
func sessionEndRequiresSessionIDWhenMultipleSessionsActive() async throws {
    try await withMemory { memory in
        let first = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        let second = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(first.isError != true)
        #expect(second.isError != true)

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "session_end", arguments: [:]),
            memory: memory
        )
        #expect(end.isError == true)
        #expect(firstText(in: end).contains("session_id is required"))
    }
}

@Test
func toolsRememberRecallSearchFlushStatsHappyPath() async throws {
    try await withMemory { memory in
        let rememberResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "Swift actors isolate mutable state.",
                    "metadata": ["source": "test-suite", "rank": 1],
                ]
            ),
            memory: memory
        )
        #expect(rememberResult.isError != true)

        let recallResult = await WaxMCPTools.handleCall(
            params: .init(name: "recall", arguments: ["query": "actors", "limit": 3]),
            memory: memory
        )
        #expect(recallResult.isError != true)
        #expect(firstText(in: recallResult).contains("Query: actors"))

        let searchResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: ["query": "actors", "mode": "text", "topK": 5]
            ),
            memory: memory
        )
        #expect(searchResult.isError != true)
        #expect(!firstText(in: searchResult).isEmpty)

        let statsResult = await WaxMCPTools.handleCall(
            params: .init(name: "stats", arguments: [:]),
            memory: memory
        )
        #expect(statsResult.isError != true)
        #expect(firstText(in: statsResult).contains("\"frameCount\""))
    }
}

@Test
func corpusSearchBuildsAcrossSessionStoresAndReturnsProvenance() async throws {
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

        let build = try await CorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(build.storesDiscovered == 2)
        #expect(build.storesSkipped == 0)
        #expect(build.documentsIndexed == 2)

        let execution = try await MCPMemoryFactory.withOpenMemory(
            at: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            structuredMemoryEnabled: false
        ) { memory in
            try await memory.searchExecution(
                query: "thruster calibration",
                mode: .text,
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
        }

        #expect(!execution.hits.isEmpty)
        let preview = execution.hits.first?.previewText ?? ""
        #expect(preview.contains("thruster"))
        #expect(preview.contains("calibration"))
        let metadata = execution.hits.first?.metadata ?? [:]
        #expect(metadata[CorpusMetadataKeys.sourceStorePath] == sourceA.path)
        #expect(metadata[CorpusMetadataKeys.sourceStoreName] == "session-a.wax")
        #expect(metadata["session_id"] == "session-a")
    }
}

@Test
func brokerCorpusSearchBuildSkipsLockedSessionStore() async throws {
    try await withTemporaryDirectory { root in
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let sourceA = sessionsDir.appendingPathComponent("session-a.wax")
        let sourceB = sessionsDir.appendingPathComponent("session-b.wax")
        let corpus = root.appendingPathComponent("corpus.wax")

        try await writeSessionStore(
            at: sourceA,
            documents: [("Unlocked session note about mission telemetry.", ["session_id": "session-a"])]
        )
        try await writeSessionStore(
            at: sourceB,
            documents: [("Locked session note about fallback navigation.", ["session_id": "session-b"])]
        )

        let lockedMemory = try await openTextOnlyMemory(at: sourceB, structuredMemoryEnabled: false)
        defer { Task { try? await lockedMemory.close() } }

        let build = try await BrokerCorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(build.storesDiscovered == 2)
        #expect(build.storesIndexed == 1)
        #expect(build.storesSkipped == 1)
        #expect(build.documentsIndexed == 1)

        let execution = try await MCPMemoryFactory.withOpenMemory(
            at: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            structuredMemoryEnabled: false
        ) { memory in
            try await memory.searchExecution(
                query: "mission telemetry",
                mode: .text,
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
        }

        #expect(!execution.hits.isEmpty)
        #expect(execution.hits.contains { ($0.previewText ?? "").contains("telemetry") })
        #expect(!execution.hits.contains { ($0.previewText ?? "").contains("navigation") })
    }
}

@Test
func corpusSearchBuildReusesExistingCorpusWhenSourcesUnchanged() async throws {
    try await withTemporaryDirectory { root in
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let source = sessionsDir.appendingPathComponent("session-a.wax")
        let corpus = root.appendingPathComponent("corpus.wax")

        try await writeSessionStore(
            at: source,
            documents: [("Manifest reuse session covering thruster telemetry.", ["session_id": "session-a"])]
        )

        let firstBuild = try await CorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(firstBuild.documentsIndexed == 1)

        let targetValuesBefore = try corpus.resourceValues(forKeys: [.contentModificationDateKey])
        let manifestURL = CorpusBuildManifestStore.manifestURL(for: corpus)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        let secondBuild = try await CorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(secondBuild.storesDiscovered == 1)
        #expect(secondBuild.storesIndexed == 0)
        #expect(secondBuild.documentsIndexed == 0)

        let targetValuesAfter = try corpus.resourceValues(forKeys: [.contentModificationDateKey])
        #expect(targetValuesAfter.contentModificationDate == targetValuesBefore.contentModificationDate)
    }
}

@Test
func brokerCorpusSearchRebuildsWhenSourceFingerprintChanges() async throws {
    try await withTemporaryDirectory { root in
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let source = sessionsDir.appendingPathComponent("session-a.wax")
        let corpus = root.appendingPathComponent("corpus.wax")

        try await writeSessionStore(
            at: source,
            documents: [("First corpus rebuild note about early telemetry.", ["session_id": "session-a"])]
        )

        _ = try await BrokerCorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )

        try FileManager.default.removeItem(at: source)
        try await writeSessionStore(
            at: source,
            documents: [("Updated corpus rebuild note with navigation lock.", ["session_id": "session-a"])]
        )

        let rebuild = try await BrokerCorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(rebuild.storesDiscovered == 1)
        #expect(rebuild.storesIndexed == 1)
        #expect(rebuild.documentsIndexed == 1)

        let execution = try await MCPMemoryFactory.withOpenMemory(
            at: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            structuredMemoryEnabled: false
        ) { memory in
            try await memory.searchExecution(
                query: "navigation lock",
                mode: .text,
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
        }

        #expect(!execution.hits.isEmpty)
        #expect(execution.hits.contains { ($0.previewText ?? "").contains("navigation") })
    }
}

@Test
func corpusSearchRejectsInvalidTopK() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "corpus_search",
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
                name: "remember",
                arguments: ["content": .string("\(queryToken) \(marker)")]
            ),
            memory: memory
        )
        #expect(rememberResult.isError != true)
        let rememberJSON = try parseJSONText(in: rememberResult)
        #expect((rememberJSON["status"] as? String) == "ok")

        let statsResult = await WaxMCPTools.handleCall(
            params: .init(name: "stats", arguments: [:]),
            memory: memory
        )
        #expect(statsResult.isError != true)
        let statsJSON = try parseJSONText(in: statsResult)
        #expect((statsJSON["pendingFrames"] as? Int ?? -1) == 0)

        let recallResult = await WaxMCPTools.handleCall(
            params: .init(name: "recall", arguments: ["query": .string(queryToken), "limit": .int(5)]),
            memory: memory
        )
        #expect(recallResult.isError != true)
        #expect(firstText(in: recallResult).contains(markerNeedle))
    }
}

@Test
func rememberRejectsLegacyCommitArgument() async throws {
    try await withMemory { memory in
        let rememberResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("legacy commit should fail"),
                    "commit": .bool(false),
                ]
            ),
            memory: memory
        )
        #expect(rememberResult.isError == true)
        #expect(firstText(in: rememberResult).contains("unsupported argument"))
    }
}

@Test
func handoffRejectsLegacyCommitArgument() async throws {
    try await withMemory { memory in
        let handoffResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "handoff",
                arguments: [
                    "content": .string("legacy handoff commit should fail"),
                    "commit": false,
                ]
            ),
            memory: memory
        )
        #expect(handoffResult.isError == true)
        #expect(firstText(in: handoffResult).contains("unsupported argument"))
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
                name: "remember",
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
                name: "remember",
                arguments: [
                    "content": .string("\(queryToken) \(allowedMarker)"),
                    "metadata": .object(["group": .string("allowed")]),
                ]
            ),
            memory: memory
        )
        #expect(allowedRemember.isError != true)

        let baselineSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: ["query": .string(queryToken), "mode": .string("text"), "topK": .int(10)]
            ),
            memory: memory
        )
        #expect(baselineSearch.isError != true)
        #expect(firstText(in: baselineSearch).contains(blockedNeedle))

        let filteredSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
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
            params: .init(name: "recall", arguments: ["query": .string(queryToken), "limit": .int(10)]),
            memory: memory
        )
        #expect(baselineRecall.isError != true)
        #expect(firstText(in: baselineRecall).contains(blockedNeedle))

        let filteredRecall = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
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
                name: "recall",
                arguments: ["query": "mode-validation", "mode": "invalid-mode"]
            ),
            memory: memory
        )
        #expect(invalidMode.isError == true)
        #expect(firstText(in: invalidMode).contains("mode"))

        let invalidTopK = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: ["query": "topk-validation", "search_top_k": 0]
            ),
            memory: memory
        )
        #expect(invalidTopK.isError == true)
        #expect(firstText(in: invalidTopK).contains("search_top_k"))
    }
}

@Test
func searchRejectsUnknownFilterKeys() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "unknown filter key",
                    "filters": .object(["unsupported": .bool(true)]),
                ]
            ),
            memory: memory
        )

        #expect(result.isError == true)
        #expect(firstText(in: result).contains("filters.unsupported"))
    }
}

@Test
func searchRejectsNonArrayLabelsFilter() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "bad labels filter",
                    "filters": .object(["labels": .string("not-an-array")]),
                ]
            ),
            memory: memory
        )

        #expect(result.isError == true)
        #expect(firstText(in: result).contains("filters.labels must be an array of strings"))
    }
}

@Test
func searchRejectsNonIntegerTimeFilters() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "bad time filter",
                    "filters": .object(["time_after_ms": .string("not-an-int")]),
                ]
            ),
            memory: memory
        )

        #expect(result.isError == true)
        #expect(firstText(in: result).contains("filters.time_after_ms must be an integer"))
    }
}

@Test
func toolsReturnValidationErrorForMissingArguments() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [:]),
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
                name: "search",
                arguments: ["query": "actors", "topK": 1.9]
            ),
            memory: memory
        )
        #expect(fractional.isError == true)
        #expect(firstText(in: fractional).contains("topK must be an integer"))

        let outOfRange = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
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
                name: "recall",
                arguments: ["query": "actors", "limit": 0]
            ),
            memory: memory,
            structuredMemoryEnabled: true
        )
        #expect(zero.isError == true)
        #expect(firstText(in: zero).contains("limit must be between 1 and"))

        let tooHigh = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
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
                name: "facts_query",
                arguments: ["subject": "agent:codex", "limit": 10]
            ),
            memory: memory,
            structuredMemoryEnabled: false
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("structured memory"))

        let knowledgeCapture = await WaxMCPTools.handleCall(
            params: .init(
                name: "knowledge_capture",
                arguments: [
                    "content": "Codex prefers focused regressions.",
                    "subject": "agent:codex",
                    "kind": "agent",
                    "predicate": "prefers",
                    "object": "focused regressions",
                ]
            ),
            memory: memory,
            structuredMemoryEnabled: false
        )
        #expect(knowledgeCapture.isError == true)
        #expect(firstText(in: knowledgeCapture).contains("structured memory"))
    }
}

@Test
func unknownToolReturnsErrorResult() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "nope", arguments: [:]),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("Unknown tool"))
    }
}

@Test
func mcpRejectsBrokerControlCommands() async throws {
    try await withMemory { memory in
        for command in ["shutdown", "exit", "quit"] {
            let result = await WaxMCPTools.handleCall(
                params: .init(name: command, arguments: [:]),
                memory: memory
            )
            #expect(result.isError == true)
            #expect(firstText(in: result).contains("Unknown tool"))
        }
    }
}

@Test
func hiddenFlushToolIsRejectedConsistently() async throws {
    try await withMemory { memory in
        for command in ["flush", "wax_flush"] {
            let result = await WaxMCPTools.handleCall(
                params: .init(name: command, arguments: [:]),
                memory: memory
            )
            #expect(result.isError == true)
            #expect(firstText(in: result).contains("Unknown tool"))
        }
    }
}

@Test
func markdownProjectionMarkerEscapesCommentTerminators() throws {
    let marker = MarkdownProjectionMarker(
        sourceKind: "daily_note",
        frameID: 7,
        memoryID: "durable:7",
        hash: "hash-->break",
        dateKey: "2026-05-17-->escape"
    )

    let comment = BrokerMarkdownSync.markerComment(marker)
    let payloadEnd = comment.index(comment.endIndex, offsetBy: -4)
    #expect(!comment[..<payloadEnd].contains("-->"))

    let parsed = BrokerMarkdownSync.parse(text: "- safe line \(comment)")
    #expect(parsed.count == 1)
    #expect(parsed[0].text == "safe line")
    #expect(parsed[0].marker == marker)
}

@Test
func markdownExportSanitizesDailySourceDateFilenames() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-source-date-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let remember = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Daily note source date must not escape the projection directory."),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
                "metadata": .object([
                    MemoryMetadataKeys.sourceKind: .string(MarkdownProjectionKind.dailyNote.rawValue),
                    MemoryMetadataKeys.sourceDate: .string("../escape"),
                ]),
            ]
        ))
        #expect(remember.ok == true)

        let export = await service.handle(.init(
            command: "markdown_export",
            arguments: ["output_dir": .string(rootURL.path)]
        ))
        #expect(export.ok == true)
        let payload = try #require(export.payload?.objectValue)
        let dailyPaths = try #require(payload["daily_note_paths"]?.arrayValue)
        let escapedURL = rootURL.appendingPathComponent("escape.md")
        #expect(!FileManager.default.fileExists(atPath: escapedURL.path))

        let memoryDir = rootURL.appendingPathComponent("memory", isDirectory: true).standardizedFileURL
        for pathValue in dailyPaths {
            let path = try #require(pathValue.stringValue)
            let url = URL(fileURLWithPath: path).standardizedFileURL
            #expect(url.deletingLastPathComponent() == memoryDir)
            #expect(!url.lastPathComponent.contains("/"))
            #expect(!url.lastPathComponent.contains(".."))
        }
    }
}

@Test
func sessionStartEndAndScopedRecallSearchWork() async throws {
    try await withMemory { memory in
        let start = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(start.isError != true)
        let startJSON = try parseJSONText(in: start)
        let sessionID = try requireString(startJSON, key: "session_id")

        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: ["content": "GLOBAL_ONLY_ABC anchor for unscoped search"]
            ),
            memory: memory
        )
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "SESSION_ONLY_XYZ anchor for scoped search",
                    "session_id": .string(sessionID),
                ]
            ),
            memory: memory
        )
        let scopedRecall = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
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
                name: "search",
                arguments: ["query": "GLOBAL_ONLY_ABC", "mode": "text", "topK": 10]
            ),
            memory: memory
        )
        #expect(unscopedSearch.isError != true)
        let unscopedSearchPayload = try parseJSONResource(in: unscopedSearch, uriSuffix: "/search-summary")
        let unscopedResults = try requireArray(unscopedSearchPayload, key: "results")
        #expect(unscopedResults.contains { (($0 as? [String: Any])?["preview"] as? String)?.contains("GLOBAL") == true })

        let scopedSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
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
        let scopedSearchPayload = try parseJSONResource(in: scopedSearch, uriSuffix: "/search-summary")
        let scopedResults = try requireArray(scopedSearchPayload, key: "results")
        #expect(!scopedResults.contains { (($0 as? [String: Any])?["preview"] as? String)?.contains("GLOBAL_ONLY_ABC") == true })

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "session_end", arguments: [:]),
            memory: memory
        )
        #expect(end.isError != true)
    }
}

@Test
func brokerCLIPathResolvesSiblingWhenLaunchedViaPath() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cliPath = tempDir.appendingPathComponent("wax-cli")
    let mcpPath = tempDir.appendingPathComponent("wax-mcp")
    try "#!/bin/sh\nexit 0\n".write(to: cliPath, atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: mcpPath, atomically: true, encoding: .utf8)
    guard chmod(cliPath.path, 0o755) == 0, chmod(mcpPath.path, 0o755) == 0 else {
        throw NSError(domain: "WaxMCPServerTests", code: 41, userInfo: [NSLocalizedDescriptionKey: "Failed to make test executables"])
    }

    let originalPath = ProcessInfo.processInfo.environment["PATH"]
    let pathPrefix = tempDir.path
    let newPath = originalPath.map { "\(pathPrefix):\($0)" } ?? pathPrefix
    setenv("PATH", newPath, 1)
    defer {
        if let originalPath {
            setenv("PATH", originalPath, 1)
        } else {
            unsetenv("PATH")
        }
    }

    let resolved = AgentBrokerPathing.resolveBrokerCLIPath(currentExecutablePath: "wax-mcp")
    #expect(resolved == cliPath.path)
}

@Test
func sessionStartDoesNotImplicitlyScopeWrites() async throws {
    try await withMemory { memory in
        let start = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(start.isError != true)
        let started = try parseJSONText(in: start)
        let sessionID = try requireString(started, key: "session_id")

        let globalWrite = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: ["content": "GLOBAL_IMPLICIT_SCOPE_GUARD"]
            ),
            memory: memory
        )
        #expect(globalWrite.isError != true)

        let scopedWrite = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "SESSION_EXPLICIT_SCOPE_GUARD",
                    "session_id": .string(sessionID),
                ]
            ),
            memory: memory
        )
        #expect(scopedWrite.isError != true)

        let scopedSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
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
        let scopedPayload = try parseJSONResource(in: scopedSearch, uriSuffix: "/search-summary")
        let scopedResults = try requireArray(scopedPayload, key: "results")
        #expect(!scopedResults.contains { (($0 as? [String: Any])?["preview"] as? String)?.contains("GLOBAL_IMPLICIT_SCOPE_GUARD") == true })

        let unscopedSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: ["query": "GLOBAL_IMPLICIT_SCOPE_GUARD", "mode": "text", "topK": 10]
            ),
            memory: memory
        )
        #expect(unscopedSearch.isError != true)
        let unscopedPayload = try parseJSONResource(in: unscopedSearch, uriSuffix: "/search-summary")
        let unscopedResults = try requireArray(unscopedPayload, key: "results")
        #expect(!unscopedResults.isEmpty)
    }
}

@Test
func rememberRejectsMetadataSessionID() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
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
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(start.isError != true)
        let started = try parseJSONText(in: start)
        let sessionID = try requireString(started, key: "session_id")

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "session_end", arguments: ["session_id": .string(sessionID)]),
            memory: memory
        )
        #expect(end.isError != true)

        let remember = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
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
                name: "search",
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
func compatMemoryGetReadsEpisodicIDsReturnedByMemorySearch() async throws {
    try await withMemory { memory in
        let start = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(start.isError != true)
        let sessionID = try requireString(try parseJSONText(in: start), key: "session_id")

        let remember = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("EPISODIC_MEMORY_GET_ROUNDTRIP compatibility memory should remain readable after the session ends."),
                    "session_id": .string(sessionID),
                ]
            ),
            memory: memory
        )
        #expect(remember.isError != true)

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "session_end", arguments: ["session_id": .string(sessionID)]),
            memory: memory
        )
        #expect(end.isError != true)

        let document = try #require(try await memory.corpusSourceDocuments().first(where: {
            $0.metadata["session_id"] == sessionID &&
            $0.text.contains("EPISODIC_MEMORY_GET_ROUNDTRIP")
        }))
        let memoryID = "episodic:\(sessionID):\(document.frameId)"

        let get = await WaxMCPTools.handleCall(
            params: .init(name: "memory_get", arguments: ["memory_id": .string(memoryID)]),
            memory: memory
        )
        #expect(get.isError != true)
        #expect(firstText(in: get).contains("EPISODIC_MEMORY_GET_ROUNDTRIP"))
    }
}

@Test
func compatCompactContextScopesToRequestedSession() async throws {
    try await withMemory { memory in
        let startA = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(startA.isError != true)
        let sessionA = try requireString(try parseJSONText(in: startA), key: "session_id")

        let startB = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(startB.isError != true)
        let sessionB = try requireString(try parseJSONText(in: startB), key: "session_id")

        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("COMPACT_CONTEXT_SCOPE_MARKER durable memory must stay out of session A checkpoints."),
                ]
            ),
            memory: memory
        )
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("COMPACT_CONTEXT_SCOPE_MARKER session A memory must remain in session A checkpoints."),
                    "session_id": .string(sessionA),
                ]
            ),
            memory: memory
        )
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("COMPACT_CONTEXT_SCOPE_MARKER session B memory must not leak into session A checkpoints."),
                    "session_id": .string(sessionB),
                ]
            ),
            memory: memory
        )

        let compact = await WaxMCPTools.handleCall(
            params: .init(
                name: "compact_context",
                arguments: [
                    "query": .string("COMPACT_CONTEXT_SCOPE_MARKER"),
                    "session_id": .string(sessionA),
                    "mode": .string("text"),
                    "max_items": .int(6),
                ]
            ),
            memory: memory
        )
        #expect(compact.isError != true)
        let payload = try parseJSONResource(in: compact, uriSuffix: "/compact-context-summary")
        let shortContext = try requireArray(payload, key: "short_context")
        #expect(!shortContext.isEmpty)
        #expect(shortContext.contains { entry in
            guard let object = try? requireObject(entry) else { return false }
            return (object["preview"] as? String)?.contains("session A memory must remain") == true
        })
        #expect(!shortContext.contains { entry in
            guard let object = try? requireObject(entry) else { return false }
            return (object["preview"] as? String)?.contains("durable memory must stay out") == true
        })
        #expect(!shortContext.contains { entry in
            guard let object = try? requireObject(entry) else { return false }
            return (object["preview"] as? String)?.contains("session B memory must not leak") == true
        })
        #expect(shortContext.allSatisfy { entry in
            guard let object = try? requireObject(entry),
                  let memoryID = object["memory_id"] as? String else { return false }
            return memoryID.hasPrefix("working:\(sessionA):")
        })

        let firstItem = try #require(shortContext.compactMap { try? requireObject($0) }.first)
        let memoryID = try requireString(firstItem, key: "memory_id")
        let get = await WaxMCPTools.handleCall(
            params: .init(name: "memory_get", arguments: ["memory_id": .string(memoryID)]),
            memory: memory
        )
        #expect(get.isError != true)
        #expect(firstText(in: get).contains("session A memory must remain"))
    }
}

@Test
func sessionEndReportsRemainingActiveSessions() async throws {
    try await withMemory { memory in
        let startA = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(startA.isError != true)
        let sessionA = try requireString(try parseJSONText(in: startA), key: "session_id")

        let startB = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(startB.isError != true)
        let sessionB = try requireString(try parseJSONText(in: startB), key: "session_id")

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "session_end", arguments: ["session_id": .string(sessionA)]),
            memory: memory
        )
        #expect(end.isError != true)
        let ended = try parseJSONText(in: end)
        #expect((ended["session_id"] as? String) == sessionA)
        #expect((ended["active"] as? Bool) == true)

        let stats = await WaxMCPTools.handleCall(
            params: .init(name: "stats", arguments: [:]),
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
        params: .init(name: "stats", arguments: [:]),
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
            name: "search",
            arguments: ["query": "VECTOR_FALLBACK_SIGNAL", "mode": "hybrid", "topK": 5]
        ),
        memory: memory
    )
    #expect(search.isError != true)
        let payload = try parseJSONResource(in: search, uriSuffix: "/search-summary")
        #expect((payload["requested_mode"] as? String) == "hybrid(alpha=0.500)")
        #expect((payload["effective_mode"] as? String) == "text")
        #expect((payload["query_embedding_state"] as? String) == "timeout")
        let results = try requireArray(payload, key: "results")
        #expect(!results.isEmpty)
        let firstResult = try requireObject(results[0])
        #expect(firstResult["frameId"] != nil)
        #expect(firstResult["sources"] != nil)

    let stats = await WaxMCPTools.handleCall(
        params: .init(name: "stats", arguments: [:]),
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
                name: "search",
                arguments: ["query": "x", "mode": "text", "session_id": "not-a-uuid"]
            ),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("session_id must be a valid UUID"))
    }
}

@Test
func recallJSONResourceIncludesStructuredResults() async throws {
    try await withMemory { memory in
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "Structured recall payload marker",
                    "metadata": ["source": "recall-json"],
                ]
            ),
            memory: memory
        )
        let recall = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: ["query": "payload marker", "limit": 3]
            ),
            memory: memory
        )

        #expect(recall.isError != true)
        let payload = try parseJSONResource(in: recall, uriSuffix: "/recall-summary")
        let results = try requireArray(payload, key: "results")
        #expect(!results.isEmpty)
        let first = try requireObject(results[0])
        #expect((first["text"] as? String)?.contains("Structured recall payload marker") == true)
        let metadata = try requireObject(first, key: "metadata")
        #expect((metadata["source"] as? String) == "recall-json")
    }
}

@Test
func handoffRoundTripAndStatsSessionBlockWork() async throws {
    try await withMemory { memory in
        let start = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        #expect(start.isError != true)
        let started = try parseJSONText(in: start)
        let sessionID = try requireString(started, key: "session_id")

        let handoff = await WaxMCPTools.handleCall(
            params: .init(
                name: "handoff",
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
                name: "handoff_latest",
                arguments: ["project": "wax"]
            ),
            memory: memory
        )
        #expect(latest.isError != true)
        let latestJSON = try parseJSONText(in: latest)
        #expect((latestJSON["content"] as? String)?.contains("Carry over refactor checkpoints") == true)

        let stats = await WaxMCPTools.handleCall(
            params: .init(name: "stats", arguments: [:]),
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
                name: "entity_upsert",
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
                name: "fact_assert",
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
                name: "facts_query",
                arguments: ["subject": "agent:codex", "predicate": "learned_behavior", "limit": 20]
            ),
            memory: memory
        )
        #expect(factsBeforeRetract.isError != true)
        #expect(firstText(in: factsBeforeRetract).contains("Prefer focused patches"))

        let retract = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_retract",
                arguments: ["fact_id": .int(factID)]
            ),
            memory: memory
        )
        #expect(retract.isError != true)

        let factsAfterRetract = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: ["subject": "agent:codex", "predicate": "learned_behavior", "limit": 20]
            ),
            memory: memory
        )
        #expect(factsAfterRetract.isError != true)
        #expect(!firstText(in: factsAfterRetract).contains("Prefer focused patches"))

        let resolve = await WaxMCPTools.handleCall(
            params: .init(
                name: "entity_resolve",
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

private func openTextOnlyMemory(
    at url: URL,
    structuredMemoryEnabled: Bool
) async throws -> MemoryOrchestrator {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = structuredMemoryEnabled
    config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)
    config.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .textOnly
    )
    return try await MemoryOrchestrator(at: url, config: config)
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
            params: .init(name: "remember", arguments: [
                "content": .string("Swift actors provide data isolation through actor-isolated state."),
            ]),
            memory: memory
        )
        #expect(remember.isError != true)
        let rememberJSON = try parseJSONText(in: remember)
        #expect((rememberJSON["status"] as? String) == "ok")
        let framesAdded = rememberJSON["framesAdded"] as? Int ?? 0
        #expect(framesAdded > 0)

        let recall = await WaxMCPTools.handleCall(
            params: .init(name: "recall", arguments: [
                "query": .string("actors"),
            ]),
            memory: memory
        )
        #expect(recall.isError != true)
        let recallText = firstText(in: recall)
        #expect(recallText.contains("Results:"))

        let search = await WaxMCPTools.handleCall(
            params: .init(name: "search", arguments: [
                "query": .string("actors"),
                "mode": .string("hybrid"),
            ]),
            memory: memory
        )
        #expect(search.isError != true)
    }
}

@Test
func compatibilitySearchAcceptsVectorMode() async throws {
    try await withVectorMemory { memory in
        try await memory.remember("Vector mode compatibility anchor")
        try await memory.flush()

        let search = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": .string("Vector mode compatibility anchor"),
                    "mode": .string("vector"),
                    "topK": .int(5),
                ]
            ),
            memory: memory
        )

        #expect(search.isError != true)
        #expect(firstText(in: search).contains("Vector mode compatibility anchor"))
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
        params: .init(name: "remember", arguments: [
            "content": .string("This should time out."),
        ]),
        memory: memory
    )
    #expect(result.isError == true)
    let text = firstText(in: result)
    #expect(text.localizedCaseInsensitiveContains("timeout") || text.localizedCaseInsensitiveContains("timed out"))
}

@Test
func rememberRejectsSecretLikeDurableMemory() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "content": .string("OPENAI_API_KEY=sk-1234567890abcdefghijklmnop"),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
            ]),
            memory: memory
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("secret-like content"))
    }
}

@Test
func rememberSearchAndRecallExposeTypedExplainableMemory() async throws {
    try await withMemory { memory in
        let remember = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "content": .string("Chris prefers concise summaries for release notes."),
                "memory_type": .string("user_preference"),
                "durability": .string("durable"),
                "project": .string("Wax"),
                "repo": .string("Wax"),
                "reviewed": .bool(true),
            ]),
            memory: memory
        )
        #expect(remember.isError != true)

        let search = await WaxMCPTools.handleCall(
            params: .init(name: "search", arguments: [
                "query": .string("concise summaries"),
                "mode": .string("text"),
            ]),
            memory: memory
        )
        #expect(search.isError != true)
        let searchJSON = try parseJSONResource(in: search, uriSuffix: "search-summary")
        let first = ((searchJSON["results"] as? [[String: Any]]) ?? []).first
        let explanations = first?["explanations"] as? [String] ?? []
        let metadata = first?["metadata"] as? [String: Any] ?? [:]
        #expect(metadata["wax.memory_type"] as? String == "user_preference")
        #expect(explanations.contains("keyword match"))
        #expect(explanations.contains("user preference"))

        let recall = await WaxMCPTools.handleCall(
            params: .init(name: "recall", arguments: [
                "query": .string("release notes preference"),
                "limit": .int(3),
            ]),
            memory: memory
        )
        #expect(recall.isError != true)
        let recallJSON = try parseJSONResource(in: recall, uriSuffix: "recall-summary")
        let recallFirst = ((recallJSON["results"] as? [[String: Any]]) ?? []).first
        let recallExplanations = recallFirst?["explanations"] as? [String] ?? []
        #expect(recallExplanations.contains("user preference"))
    }
}

@Test
func sessionSynthesizeAndPromoteFlowWorks() async throws {
    try await withMemory { memory in
        let started = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        let startedJSON = try parseJSONText(in: started)
        let sessionID = try #require(startedJSON["session_id"] as? String)

        let remember = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "session_id": .string(sessionID),
                "content": .string("Decision: Wax should default repo-scoped recall before global recall."),
            ]),
            memory: memory
        )
        #expect(remember.isError != true)

        let synthesize = await WaxMCPTools.handleCall(
            params: .init(name: "session_synthesize", arguments: [
                "session_id": .string(sessionID),
            ]),
            memory: memory
        )
        #expect(synthesize.isError != true)
        let synthesizeJSON = try parseJSONResource(in: synthesize, uriSuffix: "session-synthesize-summary")
        let candidates = synthesizeJSON["durable_candidates"] as? [[String: Any]] ?? []
        #expect(!candidates.isEmpty)
        #expect(candidates.contains { ($0["suggested_type"] as? String) == "decision" })

        let promote = await WaxMCPTools.handleCall(
            params: .init(name: "memory_promote", arguments: [
                "session_id": .string(sessionID),
                "approve": .bool(true),
            ]),
            memory: memory
        )
        #expect(promote.isError != true)
        let promoteJSON = try parseJSONText(in: promote)
        #expect((promoteJSON["written"] as? Bool) == true)

        let search = await WaxMCPTools.handleCall(
            params: .init(name: "search", arguments: [
                "query": .string("repo-scoped recall"),
                "mode": .string("text"),
            ]),
            memory: memory
        )
        let searchJSON = try parseJSONResource(in: search, uriSuffix: "search-summary")
        let results = searchJSON["results"] as? [[String: Any]] ?? []
        let durableHit = results.first {
            (($0["metadata"] as? [String: Any])?["wax.memory_type"] as? String == "decision")
                && (($0["metadata"] as? [String: Any])?["wax.reviewed"] as? String == "true")
        }
        #expect(durableHit != nil)
    }
}

@Test
func brokerMarkdownSyncRejectsSecretLikeDurableMemoryImports() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-secret-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let memoryURL = rootURL.appendingPathComponent("MEMORY.md")
        try """
        # MEMORY

        ## fact
        - api_key=12345678901234567890
        """.write(to: memoryURL, atomically: true, encoding: .utf8)

        let response = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(rootURL.path)]
        ))

        #expect(response.ok == false)
        #expect((response.error ?? "").contains("Refusing to store durable memory containing secret-like content"))
    }
}

@Test
func brokerRetrievalEventsPersistQueryHashWithoutRawQuery() async throws {
    try await withAgentBrokerService { service, sessionRootURL in
        let started = await service.handle(.init(command: "session_start"))
        let startedPayload = try #require(started.payload?.objectValue)
        let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)
        let sessionID = try #require(UUID(uuidString: sessionIDString))
        let query = "QUERY_LOG_PRIVACY_ANCHOR"

        let append = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("Remember \(query) without storing raw retrieval queries."),
                "session_id": .string(sessionIDString),
            ]
        ))
        #expect(append.ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(query),
                "mode": .string("text"),
                "topK": .int(5),
                "session_id": .string(sessionIDString),
            ]
        ))
        #expect(search.ok == true)

        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
        let events = try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
        let retrievalEvents = events.filter { $0.kind == .retrievalHit }
        #expect(!retrievalEvents.isEmpty)
        for event in retrievalEvents {
            #expect(event.payload["query"] == nil)
            #expect(event.payload["query_hash"] != nil)
        }
    }
}

@Test
func brokerRememberPreservesContentWhitespace() async throws {
    try await withAgentBrokerService { service, _ in
        let content = "  WHITESPACE_KEEP_TOKEN\n"
        let append = await service.handle(.init(
            command: "memory_append",
            arguments: ["content": .string(content)]
        ))
        #expect(append.ok == true)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string("WHITESPACE_KEEP_TOKEN"),
                "mode": .string("text"),
                "topK": .int(1),
            ]
        ))
        #expect(search.ok == true)
        let searchPayload = try #require(search.payload?.objectValue)
        let results = try #require(searchPayload["results"]?.arrayValue)
        let first = try #require(results.first?.objectValue)
        let memoryID = try #require(first["memory_id"]?.stringValue)

        let get = await service.handle(.init(
            command: "memory_get",
            arguments: ["memory_id": .string(memoryID)]
        ))
        #expect(get.ok == true)
        let getPayload = try #require(get.payload?.objectValue)
        #expect(getPayload["text"]?.stringValue == content)

        let handoffContent = "  HANDOFF_KEEP_TOKEN\n"
        let handoff = await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(handoffContent),
                "project": .string("whitespace-project"),
            ]
        ))
        #expect(handoff.ok == true)

        let latest = await service.handle(.init(
            command: "handoff_latest",
            arguments: ["project": .string("whitespace-project")]
        ))
        #expect(latest.ok == true)
        let latestPayload = try #require(latest.payload?.objectValue)
        #expect(latestPayload["content"]?.stringValue == handoffContent)
    }
}

@Test
func brokerSessionResumeSelectorSkipsEndedManifests() async throws {
    try await withAgentBrokerService { service, _ in
        let first = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("selector-agent"),
                "run_id": .string("selector-run"),
            ]
        ))
        #expect(first.ok == true)
        let firstPayload = try #require(first.payload?.objectValue)
        let firstSessionID = try #require(firstPayload["session_id"]?.stringValue)

        try await Task.sleep(for: .milliseconds(2))

        let second = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("selector-agent"),
                "run_id": .string("selector-run"),
            ]
        ))
        #expect(second.ok == true)
        let secondPayload = try #require(second.payload?.objectValue)
        let secondSessionID = try #require(secondPayload["session_id"]?.stringValue)

        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(secondSessionID)]
        ))
        #expect(ended.ok == true)

        let resumed = await service.handle(.init(
            command: "session_resume",
            arguments: [
                "agent_id": .string("selector-agent"),
                "run_id": .string("selector-run"),
            ]
        ))

        #expect(resumed.ok == true)
        let resumedPayload = try #require(resumed.payload?.objectValue)
        #expect(resumedPayload["session_id"]?.stringValue == firstSessionID)
        #expect(resumedPayload["resumed"]?.boolValue == true)
    }
}

@Test
func brokerImplicitMemoryPromotePreservesResolvedSessionProvenance() async throws {
    try await withAgentBrokerService { service, sessionRootURL in
        let started = await service.handle(.init(command: "session_start"))
        let startedPayload = try #require(started.payload?.objectValue)
        let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)
        let sessionID = try #require(UUID(uuidString: sessionIDString))

        let append = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("Decision: implicit promotion must preserve session provenance."),
                "session_id": .string(sessionIDString),
            ]
        ))
        #expect(append.ok == true)

        let promote = await service.handle(.init(
            command: "memory_promote",
            arguments: ["approve": .bool(true)]
        ))
        #expect(promote.ok == true)
        let promotePayload = try #require(promote.payload?.objectValue)
        #expect(promotePayload["written"]?.boolValue == true)
        let metadata = try #require(promotePayload["metadata"]?.objectValue)
        #expect(metadata[MemoryMetadataKeys.promotedFromSession]?.stringValue == sessionIDString)

        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
        let events = try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
        #expect(events.contains { $0.kind == .promotionWritten })
    }
}

@Test
func memorySearchSignalsInfluenceCompatSessionSynthesis() async throws {
    try await withMemory { memory in
        let started = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        let startedJSON = try parseJSONText(in: started)
        let sessionID = try #require(startedJSON["session_id"] as? String)

        let remember = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "session_id": .string(sessionID),
                "content": .string("Decision: memory_search retrieval signals should influence synthesis and promotion."),
            ]),
            memory: memory
        )
        #expect(remember.isError != true)

        for query in ["retrieval signals", "synthesis promotion"] {
            let search = await WaxMCPTools.handleCall(
                params: .init(name: "memory_search", arguments: [
                    "query": .string(query),
                    "session_id": .string(sessionID),
                    "mode": .string("text"),
                    "topK": .int(5),
                    "include_working": .bool(true),
                    "include_episodic": .bool(false),
                    "include_durable": .bool(false),
                ]),
                memory: memory
            )
            #expect(search.isError != true)
        }

        let synthesize = await WaxMCPTools.handleCall(
            params: .init(name: "session_synthesize", arguments: [
                "session_id": .string(sessionID),
            ]),
            memory: memory
        )
        #expect(synthesize.isError != true)
        let synthesizeJSON = try parseJSONResource(in: synthesize, uriSuffix: "session-synthesize-summary")
        let candidates = synthesizeJSON["durable_candidates"] as? [[String: Any]] ?? []
        let matchingCandidate = candidates.first {
            (($0["summary"] as? String) ?? "").contains("memory_search retrieval signals")
        }
        let matching = try #require(matchingCandidate)
        #expect((matching["recall_count"] as? Int ?? 0) >= 2)
        #expect((matching["unique_query_count"] as? Int ?? 0) >= 2)
        #expect((matching["average_relevance_score"] as? Double ?? 0) > 0)
    }
}

@Test
func memoryPromotePreservesLockedOverride() async throws {
    try await withMemory { memory in
        let started = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            memory: memory
        )
        let startedJSON = try parseJSONText(in: started)
        let sessionID = try #require(startedJSON["session_id"] as? String)

        let remember = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "session_id": .string(sessionID),
                "content": .string("Decision: keep broker-backed promotion overrides intact."),
            ]),
            memory: memory
        )
        #expect(remember.isError != true)

        let promote = await WaxMCPTools.handleCall(
            params: .init(name: "memory_promote", arguments: [
                "session_id": .string(sessionID),
                "approve": .bool(true),
                "locked": .bool(true),
            ]),
            memory: memory
        )
        #expect(promote.isError != true)
        let promoteJSON = try parseJSONText(in: promote)
        let metadata = try #require(promoteJSON["metadata"] as? [String: Any])
        #expect(metadata["wax.durability"] as? String == "locked")
        #expect(metadata["wax.reviewed"] as? String == "true")
    }
}

@Test
func knowledgeCaptureAndMemoryHealthWork() async throws {
    try await withMemory { memory in
        let capture = await WaxMCPTools.handleCall(
            params: .init(name: "knowledge_capture", arguments: [
                "content": .string("Wax uses a broker-owned long-term store."),
                "subject": .string("project:wax"),
                "kind": .string("project"),
                "predicate": .string("architecture"),
                "object": .string("broker-owned"),
            ]),
            memory: memory
        )
        #expect(capture.isError != true)
        let captureJSON = try parseJSONText(in: capture)
        #expect(captureJSON["durability"] as? String == "durable")

        let duplicateA = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "content": .string("Lesson: keep broker-owned long-term store access single-owner."),
                "memory_type": .string("lesson"),
            ]),
            memory: memory
        )
        #expect(duplicateA.isError != true)

        let duplicateB = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "content": .string("Lesson: keep broker-owned long-term store access single owner."),
                "memory_type": .string("lesson"),
            ]),
            memory: memory
        )
        #expect(duplicateB.isError != true)

        let conflictingFact = await WaxMCPTools.handleCall(
            params: .init(name: "fact_assert", arguments: [
                "subject": .string("project:wax"),
                "predicate": .string("architecture"),
                "object": .string("direct-store"),
            ]),
            memory: memory
        )
        #expect(conflictingFact.isError != true)

        let health = await WaxMCPTools.handleCall(
            params: .init(name: "memory_health", arguments: [:]),
            memory: memory
        )
        #expect(health.isError != true)
        let healthJSON = try parseJSONResource(in: health, uriSuffix: "memory-health-summary")
        let duplicates = healthJSON["duplicate_pairs"] as? [[String: Any]] ?? []
        let contradictions = healthJSON["contradictions"] as? [String] ?? []
        #expect(!duplicates.isEmpty)
        #expect(!contradictions.isEmpty)
    }
}

private func firstText(in result: CallTool.Result) -> String {
    for content in result.content {
        if case .text(text: let text, annotations: _, _meta: _) = content {
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

private func schemaMaximum(_ schema: Value, property: String) -> Double? {
    guard case .object(let root) = schema,
          case .object(let properties)? = root["properties"],
          case .object(let propertySchema)? = properties[property]
    else {
        return nil
    }
    switch propertySchema["maximum"] {
    case .double(let value):
        return value
    case .int(let value):
        return Double(value)
    default:
        return nil
    }
}

private func schemaEnum(_ schema: Value, property: String) -> [String]? {
    guard case .object(let root) = schema,
          case .object(let properties)? = root["properties"],
          case .object(let propertySchema)? = properties[property],
          case .array(let values)? = propertySchema["enum"]
    else {
        return nil
    }
    return values.compactMap { value in
        guard case .string(let raw) = value else { return nil }
        return raw
    }
}

private func parseToolTextJSON(fromResponseLine line: String) throws -> [String: Any] {
    guard let data = line.data(using: .utf8) else {
        throw NSError(domain: "WaxMCPServerTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 response line"])
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dict = object as? [String: Any],
          let result = dict["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]]
    else {
        throw NSError(domain: "WaxMCPServerTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "Missing tool text payload"])
    }

    if let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
       let textData = text.data(using: .utf8),
       let textObject = try? JSONSerialization.jsonObject(with: textData),
       let textDict = textObject as? [String: Any] {
        return textDict
    }

    if let resource = content.first(where: {
        ($0["type"] as? String) == "resource" &&
            ((($0["resource"] as? [String: Any])?["uri"] as? String)?.hasSuffix("tool/result") == true)
    })?["resource"] as? [String: Any],
       let text = resource["text"] as? String,
       let textData = text.data(using: .utf8),
       let resourceObject = try? JSONSerialization.jsonObject(with: textData),
       let resourceDict = resourceObject as? [String: Any] {
        return resourceDict
    }

    throw NSError(domain: "WaxMCPServerTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "Tool payload is not a JSON object"])
}

private func parseToolResourceJSON(fromResponseLine line: String, uriSuffix: String) throws -> [String: Any] {
    guard let data = line.data(using: .utf8) else {
        throw NSError(domain: "WaxMCPServerTests", code: 24, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 response line"])
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dict = object as? [String: Any],
          let result = dict["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]],
          let resource = content.first(where: {
              ($0["type"] as? String) == "resource" &&
              (($0["resource"] as? [String: Any])?["uri"] as? String)?.hasSuffix(uriSuffix) == true
          }),
          let resourceObject = resource["resource"] as? [String: Any],
          let text = resourceObject["text"] as? String,
          let textData = text.data(using: .utf8)
    else {
        throw NSError(domain: "WaxMCPServerTests", code: 25, userInfo: [NSLocalizedDescriptionKey: "Missing tool resource payload"])
    }

    let textObject = try JSONSerialization.jsonObject(with: textData)
    guard let textDict = textObject as? [String: Any] else {
        throw NSError(domain: "WaxMCPServerTests", code: 26, userInfo: [NSLocalizedDescriptionKey: "Tool resource payload is not a JSON object"])
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
    struct BootstrapResult {
        let initialize: String
        let toolsList: String?
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdoutLines: [String] = []
    private var stdoutPending = Data()
    private var stderrPending = Data()
    private var stderrLines: [String] = []
    private let brokerConfiguration: AgentBrokerConfiguration
    private let harnessRootURL: URL
    private let harnessHomeURL: URL
    private let harnessBrokerRootURL: URL

    let storeURL: URL
    var brokerSessionRootURL: URL {
        URL(fileURLWithPath: brokerConfiguration.sessionRootPath, isDirectory: true)
    }
    var brokerSocketPath: String { brokerConfiguration.socketPath }

    init(useRealEmbedder: Bool = false, storeURL: URL? = nil) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        self.storeURL = storeURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-process-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        let executableURL = try Self.waxMCPBinaryURL(packageRoot: root)
        process.executableURL = executableURL
        var args = ["--store-path", self.storeURL.path]
        if !useRealEmbedder {
            args.append("--no-embedder")
        }
        process.arguments = args
        let envRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wmh-\(Self.stableTestHash(self.storeURL.path))", isDirectory: true)
        harnessRootURL = envRoot
        harnessHomeURL = envRoot.appendingPathComponent("h", isDirectory: true)
        harnessBrokerRootURL = envRoot.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: harnessHomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: harnessBrokerRootURL, withIntermediateDirectories: true)
        let sessionRootPath = envRoot.appendingPathComponent("s", isDirectory: true).path
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = harnessHomeURL.path
        environment["WAX_BROKER_DIR"] = harnessBrokerRootURL.path
        environment["WAX_SESSION_ROOT_DIR"] = sessionRootPath
        environment["WAX_BROKER_IDLE_TIMEOUT_SECS"] = "1"
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        brokerConfiguration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: AgentBrokerPathing.resolveBrokerCLIPath(
                currentExecutablePath: executableURL.path
            ),
            storePath: self.storeURL.path,
            sessionRootPath: sessionRootPath,
            socketRootPath: harnessBrokerRootURL.path,
            embedderChoice: "minilm",
            noEmbedder: !useRealEmbedder
        )
    }

    func start() throws {
        try Self.setNonBlocking(stdoutPipe.fileHandleForReading.fileDescriptor)
        try Self.setNonBlocking(stderrPipe.fileHandleForReading.fileDescriptor)
        try process.run()
        Thread.sleep(forTimeInterval: 0.05)
    }

    func terminateIfNeeded() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                let forceDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < forceDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        try? shutdownBrokerIfRunning()
    }

    func sendJSONLine(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    func bootstrap(
        clientName: String,
        initializeID: Int = 1,
        includeToolsList: Bool = false,
        toolsListID: Int = 2,
        initializeTimeout: TimeInterval = 15,
        toolsListTimeout: TimeInterval = 15
    ) async throws -> BootstrapResult {
        try sendJSONLine([
            "jsonrpc": "2.0",
            "id": initializeID,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": clientName, "version": "1.0"],
            ],
        ])

        let initialize = try await waitForResponseLine(id: initializeID, timeout: initializeTimeout)
        try sendJSONLine([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:],
        ])

        if includeToolsList {
            try sendJSONLine([
                "jsonrpc": "2.0",
                "id": toolsListID,
                "method": "tools/list",
                "params": [:],
            ])
        }

        let toolsList = includeToolsList
            ? try await waitForResponseLine(id: toolsListID, timeout: toolsListTimeout)
            : nil
        return BootstrapResult(initialize: initialize, toolsList: toolsList)
    }

    func callTool(
        id: Int,
        name: String,
        arguments: [String: Any],
        timeout: TimeInterval = 10
    ) async throws -> String {
        try sendJSONLine([
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ])
        return try await waitForResponseLine(id: id, timeout: timeout)
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
        while Date() < deadline {
            drainAvailableOutput()
            if let line = withLocked({ stdoutLines.first(where: { Self.responseLineMatchesID($0, id: id) }) }) {
                return line
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let running = process.isRunning
        let (stderr, stdoutTail, terminationStatus) = withLocked {
            (
                stderrLines.joined(separator: "\n"),
                Array(stdoutLines.suffix(10)).joined(separator: "\n"),
                process.isRunning ? nil : process.terminationStatus
            )
        }
        throw NSError(
            domain: "MCPServerProcessHarness",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for response id \(id). " +
                    "running=\(running) terminationStatus=\(String(describing: terminationStatus)) " +
                    "stderr=\(stderr) stdoutTail=\(stdoutTail)"
            ]
        )
    }

    func waitForExit(timeout: TimeInterval = 5) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            drainAvailableOutput()
            if !process.isRunning {
                drainPipes()
                return process.terminationStatus
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "MCPServerProcessHarness", code: 3)
    }

    func waitForStderrContaining(_ needle: String, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            drainAvailableOutput()
            if withLocked({ stderrLines.joined(separator: "\n") }).contains(needle) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stderr = withLocked { stderrLines.joined(separator: "\n") }
        throw NSError(
            domain: "MCPServerProcessHarness",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for stderr containing '\(needle)'. stderr=\(stderr)"]
        )
    }

    private func drainPipes() {
        drainAvailableOutput()
    }

    private func drainAvailableOutput() {
        drainAvailableData(from: stdoutPipe.fileHandleForReading, toStdout: true)
        drainAvailableData(from: stderrPipe.fileHandleForReading, toStdout: false)
    }

    private func drainAvailableData(from handle: FileHandle, toStdout: Bool) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                appendOutput(Data(buffer[..<bytesRead]), toStdout: toStdout)
                continue
            }
            if bytesRead == 0 {
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            return
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

    private static func responseLineMatchesID(_ line: String, id: Int) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseID = object["id"]
        else {
            return false
        }

        if let responseID = responseID as? Int {
            return responseID == id
        }
        if let responseID = responseID as? NSNumber {
            return responseID.intValue == id
        }
        if let responseID = responseID as? String {
            return responseID == String(id)
        }
        return false
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

    private static func stableTestHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw NSError(
                domain: "MCPServerProcessHarness",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Unable to read file status flags for fd \(fileDescriptor)"]
            )
        }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw NSError(
                domain: "MCPServerProcessHarness",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Unable to set nonblocking mode for fd \(fileDescriptor)"]
            )
        }
    }

    func stderrSnapshot() -> String {
        withLocked { stderrLines.joined(separator: "\n") }
    }

    func shutdownBrokerIfRunning(timeout: TimeInterval = 2) throws {
        guard FileManager.default.fileExists(atPath: brokerConfiguration.socketPath) else {
            return
        }

        try Self.sendBrokerShutdownSignal(socketPath: brokerConfiguration.socketPath)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try brokerShutdownCompleted() {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func brokerShutdownCompleted() throws -> Bool {
        guard !FileManager.default.fileExists(atPath: brokerConfiguration.socketPath) else {
            return false
        }

        try StoreLockProbe.preflightExclusiveAccess(
            at: URL(fileURLWithPath: brokerConfiguration.storePath),
            timeout: .milliseconds(50)
        )
        return true
    }

    private static func sendBrokerRequest(
        _ request: AgentBrokerRequest,
        socketPath: String
    ) throws -> AgentBrokerResponse? {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return nil
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }
        defer { close(fd) }

        var address = sockaddr_un()
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            return nil
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let payload = try JSONEncoder().encode(request)
        handle.write(payload)
        handle.write(Data([0x0A]))
        shutdown(fd, SHUT_WR)

        let data = try handle.readToEnd() ?? Data()
        guard let line = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }

        return try JSONDecoder().decode(AgentBrokerResponse.self, from: Data(line.utf8))
    }

    private static func sendBrokerShutdownSignal(socketPath: String) throws {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return
        }
        defer { close(fd) }

        var address = sockaddr_un()
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            return
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let payload = try JSONEncoder().encode(AgentBrokerRequest(command: "shutdown"))
        handle.write(payload)
        handle.write(Data([0x0A]))
        shutdown(fd, SHUT_WR)
    }
}

@Suite("Wax MCP Process Tests", .serialized)
struct WaxMCPProcessTests {
    @Test
    func processHarnessUsesShortBrokerSocketPaths() throws {
        let harness = try MCPServerProcessHarness()
        defer { harness.terminateIfNeeded() }

        #expect(harness.brokerSocketPath.utf8.count < 104)
        #expect(harness.brokerSessionRootURL.path.hasPrefix("/tmp/wmh-"))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedSessionsUseHarnessIsolatedSessionRoot() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-session-root-isolation-test", includeToolsList: true)
        let started = try await harness.callTool(id: 3, name: "session_start", arguments: [:], timeout: 20)
        #expect(started.contains("store_path"))
        #expect(started.contains(harness.brokerSessionRootURL.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedRememberRejectsReservedMetadataSessionID() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-metadata-reserved-test")

        let remember = try await harness.callTool(
            id: 2,
            name: "remember",
            arguments: [
                "content": "invalid reserved metadata key",
                "metadata": ["session_id": "not-a-real-session"],
            ],
            timeout: 20
        )
        #expect(remember.contains("metadata.session_id"))
        #expect(remember.contains("reserved"))
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyWaxFlushIsRejectedBecauseFlushIsNotPublished() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-legacy-flush-test")

        let flush = try await harness.callTool(
            id: 2,
            name: "wax_flush",
            arguments: [:],
            timeout: 20
        )
        #expect(flush.contains("Unknown tool"))
    }

    @Test(.timeLimit(.minutes(1)))
    func waxMCPProcessRespondsAfterImmediateEOF() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-eof-test",
            includeToolsList: true
        )
        try harness.closeInput()

        #expect(try await harness.waitForExit(timeout: 15) == EXIT_SUCCESS)
    }

    @Test(.timeLimit(.minutes(1)))
    func waxMCPProcessPersistsCommittedWritesBeforeSIGTERM() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-sigterm-test")

        let marker = "waxmcp-sigterm-\(UUID().uuidString)"
        let remember = try await harness.callTool(
            id: 2,
            name: "remember",
            arguments: ["content": marker]
        )
        let rememberJSON = try parseToolTextJSON(fromResponseLine: remember)
        #expect((rememberJSON["status"] as? String) == "ok")

        try harness.closeInput()
        #expect(try await harness.waitForExit() == EXIT_SUCCESS)
        try harness.shutdownBrokerIfRunning()

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        let reopened = try await MemoryOrchestrator(at: harness.storeURL, config: config)
        defer { Task { try? await reopened.close() } }
        let context = try await reopened.recall(query: marker)
        #expect(context.items.contains { $0.text.contains(marker) })
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerManagedSessionLifecycleScopesRecallAndRejectsEndedHandoff() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-session-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 3, name: "session_start", arguments: [:], timeout: 20)
        let sessionStartJSON = try parseToolTextJSON(fromResponseLine: sessionStart)
        let sessionID = try requireString(sessionStartJSON, key: "session_id")

        _ = try await harness.callTool(
            id: 4,
            name: "remember",
            arguments: ["content": "GLOBAL_ONLY_ABC broker regression anchor"],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 5,
            name: "remember",
            arguments: [
                "content": "SESSION_ONLY_XYZ broker regression anchor",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let recall = try await harness.callTool(
            id: 6,
            name: "recall",
            arguments: [
                "query": "SESSION_ONLY_XYZ",
                "session_id": sessionID,
                "limit": 10,
            ],
            timeout: 20
        )
        #expect(recall.contains("SESSION_ONLY_XYZ"))
        #expect(!recall.contains("GLOBAL_ONLY_ABC"))

        _ = try await harness.callTool(
            id: 7,
            name: "session_end",
            arguments: ["session_id": sessionID],
            timeout: 20
        )

        let handoff = try await harness.callTool(
            id: 8,
            name: "handoff",
            arguments: [
                "content": "should fail after session end",
                "session_id": sessionID,
            ],
            timeout: 20
        )
        #expect(handoff.contains("session_id is not active"))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedStatsReflectActiveSessionState() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-stats-session-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 81, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 82,
            name: "remember",
            arguments: [
                "content": "SESSION_STATS_VISIBLE broker-managed session note",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let stats = try await harness.callTool(
            id: 83,
            name: "stats",
            arguments: [:],
            timeout: 20
        )
        let statsJSON = try parseToolTextJSON(fromResponseLine: stats)
        let session = try requireObject(statsJSON, key: "session")
        #expect((session["active"] as? Bool) == true)
        #expect((session["session_id"] as? String) == sessionID)
        #expect((session["sessionFrameCount"] as? Int ?? 0) >= 1)
        #expect((session["activeSessionCount"] as? Int) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedSessionSynthesizePromotesDefaultSessionWrites() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-synthesize-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 9, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 10,
            name: "remember",
            arguments: [
                "content": "Decision: promote default session notes when they clearly encode a decision.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let synthesize = try await harness.callTool(
            id: 11,
            name: "session_synthesize",
            arguments: ["session_id": sessionID],
            timeout: 20
        )
        let synthesisJSON = try parseToolResourceJSON(
            fromResponseLine: synthesize,
            uriSuffix: "session-synthesize-summary"
        )
        let candidates = try requireArray(synthesisJSON, key: "durable_candidates")
        #expect(candidates.contains { candidate in
            guard let object = try? requireObject(candidate) else {
                return false
            }
            return object["suggested_type"] as? String == "decision"
        })

        let promote = try await harness.callTool(
            id: 12,
            name: "memory_promote",
            arguments: [
                "session_id": sessionID,
                "approve": true,
            ],
            timeout: 20
        )
        let promoteJSON = try parseToolTextJSON(fromResponseLine: promote)
        let metadata = try requireObject(promoteJSON, key: "metadata")
        #expect(try requireString(metadata, key: "wax.memory_type") == "decision")
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMemorySearchSignalsInfluenceSynthesis() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-memory-search-signals",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 70, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 71,
            name: "remember",
            arguments: [
                "content": "Decision: broker memory_search retrieval signals should influence synthesis and promotion.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        for (id, query) in [(72, "retrieval signals"), (73, "synthesis promotion")] {
            _ = try await harness.callTool(
                id: id,
                name: "memory_search",
                arguments: [
                    "query": query,
                    "session_id": sessionID,
                    "mode": "text",
                    "topK": 5,
                    "include_working": true,
                    "include_episodic": false,
                    "include_durable": false,
                ],
                timeout: 20
            )
        }

        let synthesize = try await harness.callTool(
            id: 74,
            name: "session_synthesize",
            arguments: ["session_id": sessionID],
            timeout: 20
        )
        let synthesisJSON = try parseToolResourceJSON(
            fromResponseLine: synthesize,
            uriSuffix: "session-synthesize-summary"
        )
        let candidates = try requireArray(synthesisJSON, key: "durable_candidates")
        let matching = try #require(candidates.first(where: { candidate in
            guard let object = try? requireObject(candidate) else { return false }
            return ((object["summary"] as? String) ?? "").contains("broker memory_search retrieval signals")
        }))
        let matchingObject = try requireObject(matching)
        #expect((matchingObject["recall_count"] as? Int ?? 0) >= 2)
        #expect((matchingObject["unique_query_count"] as? Int ?? 0) >= 2)
        #expect((matchingObject["average_relevance_score"] as? Double ?? 0) > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerRecordRetrievalHitsCanonicalizesChunkFrameIDs() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-broker-retrieval-signals-\(UUID().uuidString)", isDirectory: true)
        let storeURL = rootURL.appendingPathComponent("memory.wax")
        let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let service = try await AgentBrokerService(
            storePath: storeURL.path,
            sessionRootPath: sessionRootURL.path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false
        )

        var deferredError: Error?
        do {
            let started = await service.handle(.init(command: "session_start"))
            #expect(started.ok == true)
            let startedPayload = try #require(started.payload?.objectValue)
            let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)
            let sessionID = try #require(UUID(uuidString: sessionIDString))

            let content = Array(
                repeating: "CHUNK_SIGNAL_ANCHOR repeated broker session content to force chunk creation and retrieval accounting coverage.",
                count: 80
            ).joined(separator: " ")
            let append = await service.handle(.init(
                command: "memory_append",
                arguments: [
                    "content": .string(content),
                    "session_id": .string(sessionIDString),
                ]
            ))
            #expect(append.ok == true)

            let search = await service.handle(.init(
                command: "search",
                arguments: [
                    "query": .string("CHUNK_SIGNAL_ANCHOR"),
                    "mode": .string("text"),
                    "topK": .int(10),
                    "session_id": .string(sessionIDString),
                ]
            ))
            #expect(search.ok == true)
            let searchPayload = try #require(search.payload?.objectValue)
            let searchResults = try #require(searchPayload["results"]?.arrayValue)
            let rawFrameID = try #require(searchResults.compactMap { result -> UInt64? in
                result.objectValue?["frameId"]?.intValue.map(UInt64.init)
            }.first)

            let memorySearch = await service.handle(.init(
                command: "memory_search",
                arguments: [
                    "query": .string("CHUNK_SIGNAL_ANCHOR"),
                    "mode": .string("text"),
                    "topK": .int(10),
                    "session_id": .string(sessionIDString),
                    "include_working": .bool(true),
                    "include_episodic": .bool(false),
                    "include_durable": .bool(false),
                ]
            ))
            #expect(memorySearch.ok == true)
            let memorySearchPayload = try #require(memorySearch.payload?.objectValue)
            let memorySearchResults = try #require(memorySearchPayload["results"]?.arrayValue)
            let canonicalFrameID = try #require(memorySearchResults.compactMap { result -> UInt64? in
                result.objectValue?["frame_id"]?.intValue.map(UInt64.init)
            }.first)
            #expect(canonicalFrameID != rawFrameID)

            let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
            let signals = BrokerSessionPersistence.recallSignals(
                from: try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
            )
            #expect(signals[rawFrameID] == nil)
            let signal = try #require(signals[canonicalFrameID])
            #expect(signal.recallCount == 2)
            #expect(signal.uniqueQueryCount == 1)
            #expect(signal.averageScore > 0)
        } catch {
            deferredError = error
        }

        do {
            try await service.close()
        } catch {
            if deferredError == nil {
                deferredError = error
            }
        }
        try? FileManager.default.removeItem(at: rootURL)
        if let deferredError {
            throw deferredError
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMemoryPromotePreservesLockedOverride() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-promote-override-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 13, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 14,
            name: "remember",
            arguments: [
                "content": "Decision: preserve promote overrides for locked durable memories.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let promote = try await harness.callTool(
            id: 15,
            name: "memory_promote",
            arguments: [
                "session_id": sessionID,
                "approve": true,
                "locked": true,
            ],
            timeout: 20
        )
        let promoteJSON = try parseToolTextJSON(fromResponseLine: promote)
        let metadata = try requireObject(promoteJSON, key: "metadata")
        #expect(try requireString(metadata, key: "wax.durability") == "locked")
        #expect(try requireString(metadata, key: "wax.reviewed") == "true")
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedKnowledgeCaptureDefaultsToDurable() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-knowledge-capture-test",
            includeToolsList: true
        )

        let capture = try await harness.callTool(
            id: 16,
            name: "knowledge_capture",
            arguments: [
                "content": "Wax keeps durable broker knowledge in the long-term store by default.",
            ],
            timeout: 20
        )
        let captureJSON = try parseToolTextJSON(fromResponseLine: capture)
        #expect(try requireString(captureJSON, key: "durability") == "durable")
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMemorySearchAndGetExposeStableMemoryIDs() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-memory-search-get-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(
            id: 17,
            name: "session_start",
            arguments: ["agent_id": "openclaw-agent", "run_id": "run-001"],
            timeout: 20
        )
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 18,
            name: "remember",
            arguments: [
                "content": "Durable memory anchor: Wax is the long-term source of truth.",
                "memory_type": "decision",
                "durability": "durable",
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 19,
            name: "memory_append",
            arguments: [
                "content": "Working memory anchor: current task is OpenClaw adapter implementation.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let search = try await harness.callTool(
            id: 20,
            name: "memory_search",
            arguments: [
                "query": "anchor",
                "session_id": sessionID,
                "topK": 6,
                "mode": "text",
            ],
            timeout: 20
        )
        let searchJSON = try parseToolResourceJSON(fromResponseLine: search, uriSuffix: "memory-search-summary")
        let results = try requireArray(searchJSON, key: "results")
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["horizon"] as? String) == "working"
        })
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["horizon"] as? String) == "durable"
        })

        let pattern = #"working:[0-9A-F-]+:[0-9]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        let searchRange = NSRange(search.startIndex..<search.endIndex, in: search)
        let match = try #require(regex.firstMatch(in: search, range: searchRange))
        let workingRange = try #require(Range(match.range, in: search))
        let workingID = String(search[workingRange])

        let get = try await harness.callTool(
            id: 21,
            name: "memory_get",
            arguments: ["memory_id": workingID],
            timeout: 20
        )
        #expect(get.contains("OpenClaw adapter implementation"))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedSessionResumeReopensPersistedSessionAfterRestart() async throws {
        let sharedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-session-resume-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        let first = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try first.start()
        _ = try await first.bootstrap(clientName: "wax-mcp-session-resume-first", includeToolsList: true)

        let started = try await first.callTool(
            id: 31,
            name: "session_start",
            arguments: ["agent_id": "openclaw-agent", "run_id": "resume-run"],
            timeout: 20
        )
        let startedJSON = try parseToolTextJSON(fromResponseLine: started)
        let sessionID = try requireString(startedJSON, key: "session_id")

        _ = try await first.callTool(
            id: 32,
            name: "memory_append",
            arguments: [
                "content": "Resume anchor: persisted session memory survives broker restart.",
                "session_id": sessionID,
            ],
            timeout: 20
        )
        first.terminateIfNeeded()

        let second = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try second.start()
        defer { second.terminateIfNeeded() }
        _ = try await second.bootstrap(clientName: "wax-mcp-session-resume-second", includeToolsList: true)

        let resumed = try await second.callTool(
            id: 33,
            name: "session_resume",
            arguments: ["session_id": sessionID],
            timeout: 20
        )
        let resumedJSON = try parseToolTextJSON(fromResponseLine: resumed)
        #expect((resumedJSON["resumed"] as? Bool) == true)

        let search = try await second.callTool(
            id: 34,
            name: "memory_search",
            arguments: [
                "query": "resume anchor",
                "session_id": sessionID,
                "mode": "text",
            ],
            timeout: 20
        )
        let searchJSON = try parseToolResourceJSON(fromResponseLine: search, uriSuffix: "memory-search-summary")
        let results = try requireArray(searchJSON, key: "results")
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["preview"] as? String)?.contains("persisted session memory survives broker restart") == true
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedCompactContextDoesNotLoseSessionMemoryAcrossRepeatedCheckpoints() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-compact-context-test",
            includeToolsList: true
        )

        let started = try await harness.callTool(id: 41, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: started), key: "session_id")

        _ = try await harness.callTool(
            id: 42,
            name: "memory_append",
            arguments: [
                "content": "Checkpoint anchor: do not lose session memory after repeated compact_context calls.",
                "session_id": sessionID,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 43,
            name: "memory_append",
            arguments: [
                "content": "Context budget anchor: preserve session notes while compacting.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let compactA = try await harness.callTool(
            id: 44,
            name: "compact_context",
            arguments: [
                "query": "checkpoint anchor",
                "session_id": sessionID,
                "token_budget": 512,
                "mode": "text",
            ],
            timeout: 20
        )
        let compactAJSON = try parseToolResourceJSON(fromResponseLine: compactA, uriSuffix: "compact-context-summary")
        #expect(try requireString(compactAJSON, key: "compacted_text").contains("Checkpoint anchor"))

        _ = try await harness.callTool(
            id: 45,
            name: "compact_context",
            arguments: [
                "query": "context budget anchor",
                "session_id": sessionID,
                "token_budget": 512,
                "mode": "text",
            ],
            timeout: 20
        )

        let search = try await harness.callTool(
            id: 46,
            name: "memory_search",
            arguments: [
                "query": "checkpoint anchor",
                "session_id": sessionID,
                "mode": "text",
            ],
            timeout: 20
        )
        let searchJSON = try parseToolResourceJSON(fromResponseLine: search, uriSuffix: "memory-search-summary")
        let results = try requireArray(searchJSON, key: "results")
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["preview"] as? String)?.contains("do not lose session memory") == true
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMemorySearchDoesNotLeakAcrossSessions() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-cross-session-isolation-test",
            includeToolsList: true
        )

        let startedA = try await harness.callTool(id: 47, name: "session_start", arguments: [:], timeout: 20)
        let sessionA = try requireString(try parseToolTextJSON(fromResponseLine: startedA), key: "session_id")
        let startedB = try await harness.callTool(id: 48, name: "session_start", arguments: [:], timeout: 20)
        let sessionB = try requireString(try parseToolTextJSON(fromResponseLine: startedB), key: "session_id")

        _ = try await harness.callTool(
            id: 49,
            name: "memory_append",
            arguments: [
                "content": "SESSION_A_PRIVATE_ANCHOR do not leak this note into other session searches.",
                "session_id": sessionA,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 50,
            name: "memory_append",
            arguments: [
                "content": "SESSION_B_PRIVATE_ANCHOR this note belongs only to session B.",
                "session_id": sessionB,
            ],
            timeout: 20
        )

        let isolated = try await harness.callTool(
            id: 51,
            name: "memory_search",
            arguments: [
                "query": "SESSION_B_PRIVATE_ANCHOR",
                "session_id": sessionA,
                "mode": "text",
                "topK": 5,
            ],
            timeout: 20
        )
        let isolatedJSON = try parseToolResourceJSON(fromResponseLine: isolated, uriSuffix: "memory-search-summary")
        let isolatedResults = try requireArray(isolatedJSON, key: "results")
        #expect(!isolatedResults.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["preview"] as? String)?.contains("SESSION_B_PRIVATE_ANCHOR") == true
        })

        let visible = try await harness.callTool(
            id: 52,
            name: "memory_search",
            arguments: [
                "query": "SESSION_A_PRIVATE_ANCHOR",
                "session_id": sessionA,
                "mode": "text",
                "topK": 5,
            ],
            timeout: 20
        )
        let visibleJSON = try parseToolResourceJSON(fromResponseLine: visible, uriSuffix: "memory-search-summary")
        let visibleResults = try requireArray(visibleJSON, key: "results")
        #expect(!visibleResults.isEmpty)
        #expect(visibleResults.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["session_id"] as? String) == sessionA && (object["horizon"] as? String) == "working"
        })
    }

    @Test(.timeLimit(.minutes(2)))
    func brokerBackedHighVolumeWorkingMemoryRemainsSearchable() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-high-volume-session-test",
            includeToolsList: true
        )

        let started = try await harness.callTool(id: 53, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: started), key: "session_id")

        for index in 0..<8 {
            _ = try await harness.callTool(
                id: 100 + index,
                name: "memory_append",
                arguments: [
                    "content": "HIGH_VOLUME_ANCHOR_\(index) broker session memory event \(index) for endurance coverage.",
                    "session_id": sessionID,
                ],
                timeout: 20
            )
        }

        _ = try await harness.callTool(
            id: 180,
            name: "compact_context",
            arguments: [
                "query": "HIGH_VOLUME_ANCHOR_5",
                "session_id": sessionID,
                "token_budget": 768,
                "mode": "text",
            ],
            timeout: 20
        )

        let search = try await harness.callTool(
            id: 181,
            name: "memory_search",
            arguments: [
                "query": "HIGH_VOLUME_ANCHOR_5",
                "session_id": sessionID,
                "mode": "text",
                "topK": 8,
            ],
            timeout: 20
        )
        let searchJSON = try parseToolResourceJSON(fromResponseLine: search, uriSuffix: "memory-search-summary")
        let results = try requireArray(searchJSON, key: "results")
        #expect(!results.isEmpty)
        #expect(search.contains("HIGH_VOLUME_ANCHOR_5"))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMarkdownExportProjectsCompatibilityFiles() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-markdown-export-test",
            includeToolsList: true
        )

        let started = try await harness.callTool(id: 51, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: started), key: "session_id")

        _ = try await harness.callTool(
            id: 52,
            name: "remember",
            arguments: [
                "content": "Markdown export anchor: durable facts should project into MEMORY.md.",
                "memory_type": "fact",
                "durability": "durable",
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 53,
            name: "remember",
            arguments: [
                "content": "Decision: use Markdown approvals to promote durable OpenClaw learnings.",
                "session_id": sessionID,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 54,
            name: "handoff",
            arguments: [
                "content": "Markdown export handoff anchor.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-export-\(UUID().uuidString)", isDirectory: true)

        let export = try await harness.callTool(
            id: 55,
            name: "markdown_export",
            arguments: [
                "output_dir": outputDir.path,
                "session_id": sessionID,
            ],
            timeout: 20
        )
        let exportJSON = try parseToolTextJSON(fromResponseLine: export)
        let memoryPath = try requireString(exportJSON, key: "memory_md_path")
        let memoryText = try String(contentsOfFile: memoryPath, encoding: .utf8)
        #expect(memoryText.contains("Markdown export anchor"))

        let handoffPath = try #require(exportJSON["handoff_summary_path"] as? String)
        let handoffText = try String(contentsOfFile: handoffPath, encoding: .utf8)
        #expect(handoffText.contains("Markdown export handoff anchor"))

        let dreamsPath = try #require(exportJSON["dreams_path"] as? String)
        let dreamsText = try String(contentsOfFile: dreamsPath, encoding: .utf8)
        #expect(dreamsText.contains("Markdown approvals"))
        #expect(dreamsText.contains("- [ ]"))
    }

    @Test(.timeLimit(.minutes(2)))
    func brokerBackedMarkdownSyncReconcilesManagedFilesAndApprovesDreams() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-markdown-sync-test",
            includeToolsList: true
        )

        let started = try await harness.callTool(id: 61, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: started), key: "session_id")

        _ = try await harness.callTool(
            id: 62,
            name: "remember",
            arguments: [
                "content": "Original markdown-managed fact anchor.",
                "memory_type": "fact",
                "durability": "durable",
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 63,
            name: "remember",
            arguments: [
                "content": "Decision: promote DREAMS approvals into durable memory.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-sync-\(UUID().uuidString)", isDirectory: true)
        let export = try await harness.callTool(
            id: 64,
            name: "markdown_export",
            arguments: [
                "output_dir": outputDir.path,
                "session_id": sessionID,
            ],
            timeout: 20
        )
        let exportJSON = try parseToolTextJSON(fromResponseLine: export)
        let memoryPath = try requireString(exportJSON, key: "memory_md_path")
        let dreamsPath = try #require(exportJSON["dreams_path"] as? String)
        let dailyPaths = try requireArray(exportJSON, key: "daily_note_paths")
        let dailyPath = try #require(dailyPaths.first as? String)

        var memoryText = try String(contentsOfFile: memoryPath, encoding: .utf8)
        memoryText = memoryText.replacingOccurrences(
            of: "Original markdown-managed fact anchor.",
            with: "Updated markdown-managed fact anchor."
        )
        try memoryText.write(toFile: memoryPath, atomically: true, encoding: .utf8)

        var dailyText = try String(contentsOfFile: dailyPath, encoding: .utf8)
        dailyText.append("\n- Imported daily note anchor.\n")
        try dailyText.write(toFile: dailyPath, atomically: true, encoding: .utf8)

        var dreamsText = try String(contentsOfFile: dreamsPath, encoding: .utf8)
        dreamsText = dreamsText.replacingOccurrences(of: "- [ ]", with: "- [x]", options: [], range: dreamsText.range(of: "- [ ]"))
        try dreamsText.write(toFile: dreamsPath, atomically: true, encoding: .utf8)

        let sync = try await harness.callTool(
            id: 65,
            name: "markdown_sync",
            arguments: [
                "root_dir": outputDir.path,
            ],
            timeout: 60
        )
        let syncJSON = try parseToolTextJSON(fromResponseLine: sync)
        let counts = try requireObject(syncJSON, key: "counts")
        #expect((counts["updated"] as? Int ?? 0) >= 1)
        #expect((counts["created"] as? Int ?? 0) >= 1)
        #expect((counts["approved_dreams"] as? Int ?? 0) >= 1)

        let updatedFact = try await harness.callTool(
            id: 66,
            name: "search",
            arguments: [
                "query": "Updated markdown-managed fact anchor",
                "topK": 5,
            ],
            timeout: 20
        )
        #expect(updatedFact.contains("Updated markdown-managed fact anchor"))

        let importedDaily = try await harness.callTool(
            id: 67,
            name: "search",
            arguments: [
                "query": "Imported daily note anchor",
                "topK": 5,
            ],
            timeout: 20
        )
        #expect(importedDaily.contains("Imported daily note anchor"))

        let approvedDream = try await harness.callTool(
            id: 68,
            name: "search",
            arguments: [
                "query": "promote DREAMS approvals into durable memory",
                "topK": 5,
            ],
            timeout: 20
        )
        #expect(approvedDream.contains("DREAMS approvals"))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerAutoStartHandlesConcurrentFirstAccess() async throws {
        let sharedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-concurrent-start-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        let first = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        let second = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try first.start()
        try second.start()
        defer {
            first.terminateIfNeeded()
            second.terminateIfNeeded()
        }

        async let firstBootstrap: MCPServerProcessHarness.BootstrapResult = first.bootstrap(
            clientName: "wax-mcp-concurrent-first",
            initializeID: 11,
            includeToolsList: true,
            toolsListID: 12,
            initializeTimeout: 30,
            toolsListTimeout: 20
        )
        async let secondBootstrap: MCPServerProcessHarness.BootstrapResult = second.bootstrap(
            clientName: "wax-mcp-concurrent-second",
            initializeID: 21,
            includeToolsList: true,
            toolsListID: 22,
            initializeTimeout: 30,
            toolsListTimeout: 20
        )
        let firstResult = try await firstBootstrap
        let secondResult = try await secondBootstrap

        #expect(firstResult.initialize.contains(#""protocolVersion":"2024-11-05""#))
        #expect(firstResult.toolsList?.contains(#""name":"remember""#) == true)
        #expect(secondResult.initialize.contains(#""protocolVersion":"2024-11-05""#))
        #expect(secondResult.toolsList?.contains(#""name":"remember""#) == true)
    }

    @Test(.timeLimit(.minutes(3)))
    func waxMCPProcessRememberWithRealCoreMLEmbedder() async throws {
        let harness = try MCPServerProcessHarness(useRealEmbedder: true)
        try harness.start()
        defer { harness.terminateIfNeeded() }

        let initStart = Date()
        let bootstrap = try await harness.bootstrap(
            clientName: "wax-mcp-coreml-test",
            includeToolsList: true,
            toolsListID: 99,
            initializeTimeout: 20,
            toolsListTimeout: 5
        )
        let initElapsed = Date().timeIntervalSince(initStart)
        #expect(bootstrap.initialize.contains(#""protocolVersion":"2024-11-05""#))
        #expect(initElapsed < 10)

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

        let rememberResp = try await harness.callTool(
            id: 2,
            name: "remember",
            arguments: ["content": longContent],
            timeout: 120
        )
        let rememberJSON = try parseToolTextJSON(fromResponseLine: rememberResp)
        #expect((rememberJSON["status"] as? String) == "ok")

        let recallResp = try await harness.callTool(
            id: 3,
            name: "recall",
            arguments: ["query": "Swift concurrency", "limit": 3],
            timeout: 30
        )
        #expect(recallResp.contains("result"))

        try harness.closeInput()
        #expect(try await harness.waitForExit(timeout: 10) == EXIT_SUCCESS)
        let stderr = harness.stderrSnapshot()
        #expect(stderr.contains("wax-mcp v\(WaxMCPServerMetadata.version) starting"))
    }

    @Test(.timeLimit(.minutes(1)))
    func waxMCPStartupReusesBrokerForSharedStore() async throws {
        let sharedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-startup-lock-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        let first = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try first.start()
        defer { first.terminateIfNeeded() }

        _ = try await first.bootstrap(
            clientName: "wax-mcp-first-lock-test",
            includeToolsList: true
        )

        let second = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        let start = Date()
        try second.start()
        defer { second.terminateIfNeeded() }

        let bootstrap = try await second.bootstrap(
            clientName: "wax-mcp-second-lock-test",
            includeToolsList: true,
            initializeTimeout: 10,
            toolsListTimeout: 10
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 4)
        let stderr = second.stderrSnapshot()
        #expect(bootstrap.initialize.contains(#""protocolVersion":"2024-11-05""#))
        #expect(bootstrap.toolsList?.contains(#""name":"remember""#) == true)
        #expect(!stderr.localizedCaseInsensitiveContains("use a unique --store-path"))
    }

    @Test(.timeLimit(.minutes(1)))
    func corpusSearchSkipsLockedBrokerManagedSessionStore() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-corpus-locked-session-test",
            includeToolsList: true
        )

        let lockedSessionStart = try await harness.callTool(id: 30, name: "session_start", arguments: [:], timeout: 20)
        let lockedSessionID = try requireString(try parseToolTextJSON(fromResponseLine: lockedSessionStart), key: "session_id")
        _ = try await harness.callTool(
            id: 31,
            name: "remember",
            arguments: [
                "content": "LOCKED_CORPUS_ONLY broker-managed session note",
                "session_id": lockedSessionID,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 32,
            name: "session_end",
            arguments: ["session_id": lockedSessionID],
            timeout: 20
        )

        let unlockedSessionStart = try await harness.callTool(id: 33, name: "session_start", arguments: [:], timeout: 20)
        let unlockedSessionID = try requireString(try parseToolTextJSON(fromResponseLine: unlockedSessionStart), key: "session_id")
        _ = try await harness.callTool(
            id: 34,
            name: "remember",
            arguments: [
                "content": "UNLOCKED_CORPUS_MATCH broker-managed session note",
                "session_id": unlockedSessionID,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 35,
            name: "session_end",
            arguments: ["session_id": unlockedSessionID],
            timeout: 20
        )

        let lockedStoreURL = harness.brokerSessionRootURL
            .appendingPathComponent("\(lockedSessionID).wax")
        let lockHolder = try await openTextOnlyMemory(at: lockedStoreURL, structuredMemoryEnabled: false)
        defer { Task { try? await lockHolder.close() } }

        let corpusSearch = try await harness.callTool(
            id: 36,
            name: "corpus_search",
            arguments: [
                "query": "UNLOCKED_CORPUS_MATCH",
                "mode": "text",
                "topK": 5,
                "rebuild": true,
            ],
            timeout: 20
        )
        let payload = try parseToolResourceJSON(
            fromResponseLine: corpusSearch,
            uriSuffix: "/corpus-search-summary"
        )
        let build = try requireObject(payload, key: "build")
        #expect(try requireInt(build, key: "stores_discovered") >= 2)
        #expect(try requireInt(build, key: "stores_indexed") >= 1)
        #expect(try requireInt(build, key: "stores_skipped") >= 1)
        let results = try requireArray(payload, key: "results")
        #expect(!results.isEmpty)
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else {
                return false
            }
            let preview = object["preview"] as? String ?? ""
            return preview.contains("UNLOCKED") && preview.contains("MATCH")
        })
    }
}

#else
@Test
func mcpServerTestsRequireTrait() {
    #expect(Bool(true))
}
#endif
