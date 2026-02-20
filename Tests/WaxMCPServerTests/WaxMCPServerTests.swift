import Foundation
import Testing

#if MCPServer
import MCP
@testable import WaxMCPServer
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
    #expect(names.contains("wax_video_ingest"))
    #expect(names.contains("wax_video_recall"))
    #expect(names.contains("wax_photo_ingest"))
    #expect(names.contains("wax_photo_recall"))
    // Verify no duplicate tool names
    #expect(names.count == ToolSchemas.allTools.count)
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
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(rememberResult.isError != true)

        let flushResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(flushResult.isError != true)
        #expect(firstText(in: flushResult).contains("Flushed."))

        let recallResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_recall", arguments: ["query": "actors", "limit": 3]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(recallResult.isError != true)
        #expect(firstText(in: recallResult).contains("Query: actors"))

        let searchResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "actors", "mode": "text", "topK": 5]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(searchResult.isError != true)
        #expect(!firstText(in: searchResult).isEmpty)

        let statsResult = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(statsResult.isError != true)
        #expect(firstText(in: statsResult).contains("\"frameCount\""))
    }
}

@Test
func toolsReturnValidationErrorForMissingArguments() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "wax_remember", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
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
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(fractional.isError == true)
        #expect(firstText(in: fractional).contains("topK must be an integer"))

        let outOfRange = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "actors", "topK": 1e100]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(outOfRange.isError == true)
        #expect(firstText(in: outOfRange).contains("topK is out of range"))
    }
}

@Test
func unknownToolReturnsErrorResult() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "wax_nope", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
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
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(start.isError != true)
        let startJSON = try parseJSONText(in: start)
        let sessionID = try requireString(startJSON, key: "session_id")

        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: ["content": "GLOBAL_ONLY_ABC anchor for unscoped search"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: ["content": "SESSION_ONLY_XYZ anchor for scoped search"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        _ = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )

        let scopedRecall = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_recall",
                arguments: ["query": "SESSION_ONLY_XYZ", "session_id": .string(sessionID), "limit": 10]
            ),
            memory: memory,
            video: nil,
            photo: nil
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
            memory: memory,
            video: nil,
            photo: nil
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
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(scopedSearch.isError != true)
        #expect(!firstText(in: scopedSearch).contains("GLOBAL_ONLY_ABC"))

        let end = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_end", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(end.isError != true)
    }
}

@Test
func invalidSessionIDIsRejected() async throws {
    try await withMemory { memory in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "x", "mode": "text", "session_id": "not-a-uuid"]
            ),
            memory: memory,
            video: nil,
            photo: nil
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
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(start.isError != true)
        let started = try parseJSONText(in: start)
        let sessionID = try requireString(started, key: "session_id")

        let handoff = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_handoff",
                arguments: [
                    "content": "Carry over refactor checkpoints",
                    "project": "wax",
                    "pending_tasks": ["add graph tests", "measure ranking drift"],
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(handoff.isError != true)

        let latest = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_handoff_latest",
                arguments: ["project": "wax"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(latest.isError != true)
        let latestJSON = try parseJSONText(in: latest)
        #expect((latestJSON["content"] as? String)?.contains("Carry over refactor checkpoints") == true)

        _ = await WaxMCPTools.handleCall(
            params: .init(name: "wax_flush", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )

        let stats = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
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
            memory: memory,
            video: nil,
            photo: nil
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
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(assert.isError != true)
        let asserted = try parseJSONText(in: assert)
        let factID = try requireInt(asserted, key: "fact_id")

        let factsBeforeRetract = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: ["subject": "agent:codex", "predicate": "learned_behavior", "limit": 20]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(factsBeforeRetract.isError != true)
        #expect(firstText(in: factsBeforeRetract).contains("Prefer focused patches"))

        let retract = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_retract",
                arguments: ["fact_id": .int(factID)]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(retract.isError != true)

        let factsAfterRetract = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: ["subject": "agent:codex", "predicate": "learned_behavior", "limit": 20]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(factsAfterRetract.isError != true)
        #expect(!firstText(in: factsAfterRetract).contains("Prefer focused patches"))

        let resolve = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_resolve",
                arguments: ["alias": "codex", "limit": 5]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(resolve.isError != true)
        #expect(firstText(in: resolve).contains("agent:codex"))
    }
}

@Test
func photoToolsReturnSojuRedirectAsError() async throws {
    try await withMemory { memory in
        let ingest = await WaxMCPTools.handleCall(
            params: .init(name: "wax_photo_ingest", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(ingest.isError == true)
        #expect(firstText(in: ingest).contains("waxmcp.dev/soju"))

        let recall = await WaxMCPTools.handleCall(
            params: .init(name: "wax_photo_recall", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(recall.isError == true)
        #expect(firstText(in: recall).contains("waxmcp.dev/soju"))
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
        .appendingPathExtension("mv2s")
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
#else
@Test
func mcpServerTestsRequireTrait() {
    #expect(Bool(true))
}
#endif
