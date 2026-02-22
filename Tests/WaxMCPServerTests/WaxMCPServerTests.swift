import Foundation
import Testing

#if MCPServer
import CoreGraphics
import MCP
@testable import WaxMCPServer
import Wax

private struct StubVideoEmbedder: MultimodalEmbeddingProvider {
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "test-provider",
        model: "test-video",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return [1, 0, 0, 0]
    }
}

private struct StubTextEmbedder: EmbeddingProvider {
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "stub-text",
        model: "stub-v1",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }
}

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
func storePathResolverAllowsRelativePathWithinSafeRoot() throws {
    let safeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-safe-root-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: safeRoot) }

    try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)
    let resolved = try StorePathResolver.resolveStoreURL("nested/memory.mv2s", safeRoot: safeRoot)
    #expect(resolved.path.hasPrefix(safeRoot.path + "/"))
    #expect(FileManager.default.fileExists(atPath: safeRoot.appendingPathComponent("nested").path))
}

@Test
func storePathResolverRejectsTraversalOutsideSafeRoot() throws {
    let safeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-safe-root-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: safeRoot) }

    try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)
    do {
        _ = try StorePathResolver.resolveStoreURL("../escape/memory.mv2s", safeRoot: safeRoot)
        #expect(Bool(false))
    } catch {
        #expect(String(describing: error).contains("safe root"))
    }
}

@Test
func storePathResolverRejectsSymlinkEscape() throws {
    let rootBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-safe-root-\(UUID().uuidString)", isDirectory: true)
    let safeRoot = rootBase.appendingPathComponent("safe", isDirectory: true)
    let outside = rootBase.appendingPathComponent("outside", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootBase) }

    try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: safeRoot.appendingPathComponent("link"),
        withDestinationURL: outside
    )

    do {
        _ = try StorePathResolver.resolveStoreURL(
            safeRoot.appendingPathComponent("link/memory.mv2s").path,
            safeRoot: safeRoot
        )
        #expect(Bool(false))
    } catch {
        #expect(String(describing: error).contains("safe root"))
    }
}

@Test
func storePathResolverRejectsFinalResolvedPathOutsideSafeRoot() throws {
    let rootBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-safe-root-\(UUID().uuidString)", isDirectory: true)
    let safeRoot = rootBase.appendingPathComponent("safe", isDirectory: true)
    let outside = rootBase.appendingPathComponent("outside", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootBase) }

    try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    let symlinkPath = safeRoot.appendingPathComponent("memory-link.mv2s")
    let outsideFile = outside.appendingPathComponent("outside.mv2s")
    try Data("outside".utf8).write(to: outsideFile)
    try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outsideFile)

    do {
        _ = try StorePathResolver.resolveStoreURL("memory-link.mv2s", safeRoot: safeRoot)
        #expect(Bool(false))
    } catch {
        #expect(String(describing: error).contains("resolves outside safe root"))
    }
}

@Test
func featureFlagParsingCoversTruthyFalsyAndFallbackValues() {
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting("1", default: false) == true)
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting("TrUe", default: false) == true)
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting(" yes ", default: false) == true)
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting("on", default: false) == true)

    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting("0", default: true) == false)
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting("FALSE", default: true) == false)
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting(" no ", default: true) == false)
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting("off", default: true) == false)

    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting(nil, default: true) == true)
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting("   ", default: false) == false)
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting("maybe", default: true) == true)
    #expect(WaxMCPServerCommand._parseFeatureFlagForTesting("maybe", default: false) == false)
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

@Test
func storePathResolverRejectsEmptyInputs() throws {
    do {
        _ = try StorePathResolver.resolveSafeRootURL("   ")
        #expect(Bool(false))
    } catch {
        #expect(String(describing: error).contains("Safe root cannot be empty"))
    }

    let safeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-safe-root-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: safeRoot) }
    try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)

    do {
        _ = try StorePathResolver.resolveStoreURL("   ", safeRoot: safeRoot)
        #expect(Bool(false))
    } catch {
        #expect(String(describing: error).contains("Store path cannot be empty"))
    }
}

@Test
func storePathResolverAllowsAbsolutePathWithinSafeRoot() throws {
    let safeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-safe-root-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: safeRoot) }

    try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)

    let absolute = safeRoot
        .appendingPathComponent("child/memory.mv2s", isDirectory: false)
        .path
    let resolved = try StorePathResolver.resolveStoreURL(absolute, safeRoot: safeRoot)

    #expect(resolved.standardizedFileURL.path == URL(fileURLWithPath: absolute).standardizedFileURL.path)
    #expect(resolved.path.hasPrefix(safeRoot.path + "/"))
    #expect(FileManager.default.fileExists(atPath: safeRoot.appendingPathComponent("child").path))
}

@Test
func searchAndEntityResolveRejectInvalidModesAndLimits() async throws {
    try await withMemory { memory in
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: ["content": "hybrid fallback coverage text"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )

        let invalidMode = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "actors", "mode": "vector", "topK": 5]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidMode.isError == true)
        #expect(firstText(in: invalidMode).contains("mode must be one of: text, hybrid"))

        let invalidTopK = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "actors", "topK": 0]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidTopK.isError == true)
        #expect(firstText(in: invalidTopK).contains("topK must be between"))

        let whitespaceModeFallsBackToHybrid = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_search",
                arguments: ["query": "coverage", "mode": "  ", "topK": 5]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(whitespaceModeFallsBackToHybrid.isError != true)

        let invalidResolveLimit = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_resolve",
                arguments: ["alias": "codex", "limit": 0]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidResolveLimit.isError == true)
        #expect(firstText(in: invalidResolveLimit).contains("limit must be between 1 and 100"))
    }
}

@Test
func handoffLatestReturnsFoundFalseWhenNoHandoffExists() async throws {
    try await withMemory { memory in
        let latest = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_handoff_latest",
                arguments: ["project": "missing-project"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(latest.isError != true)
        let json = try parseJSONText(in: latest)
        #expect((json["found"] as? Bool) == false)
    }
}

@Test
func videoToolsReturnUnavailableWhenVideoRAGNotConfigured() async throws {
    try await withMemory { memory in
        let ingest = await WaxMCPTools.handleCall(
            params: .init(name: "wax_video_ingest", arguments: ["paths": .array([.string("/tmp/missing.mp4")])]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(ingest.isError == true)
        #expect(firstText(in: ingest).contains("Video RAG is unavailable"))

        let recall = await WaxMCPTools.handleCall(
            params: .init(name: "wax_video_recall", arguments: ["query": "alpha"]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(recall.isError == true)
        #expect(firstText(in: recall).contains("Video RAG is unavailable"))
    }
}

@Test
func videoToolsValidatePathCountAndCustomIDWhenVideoConfigured() async throws {
    try await withMemoryAndVideo { memory, video in
        let tooManyPaths = (0...50).map { Value.string("/tmp/wax-mcp-video-\($0).mp4") }
        let tooMany = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_video_ingest",
                arguments: ["paths": .array(tooManyPaths)]
            ),
            memory: memory,
            video: video,
            photo: nil
        )
        #expect(tooMany.isError == true)
        #expect(firstText(in: tooMany).contains("supports up to"))

        let customIDWithMultiplePaths = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_video_ingest",
                arguments: [
                    "paths": .array([.string("/tmp/a.mp4"), .string("/tmp/b.mp4")]),
                    "id": .string("custom-video-id"),
                ]
            ),
            memory: memory,
            video: video,
            photo: nil
        )
        #expect(customIDWithMultiplePaths.isError == true)
        #expect(firstText(in: customIDWithMultiplePaths).contains("exactly one path"))

        let missingFile = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_video_ingest",
                arguments: ["paths": .array([.string("/tmp/definitely-missing-video.mp4")])]
            ),
            memory: memory,
            video: video,
            photo: nil
        )
        #expect(missingFile.isError == true)
        #expect(firstText(in: missingFile).contains("video file does not exist"))
    }
}

@Test
func videoRecallValidatesTimeRangeAndSupportsEmptyContext() async throws {
    try await withMemoryAndVideo { memory, video in
        let invalidRangeOrder = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_video_recall",
                arguments: [
                    "query": .string("alpha"),
                    "time_range": .object([
                        "start": .double(10),
                        "end": .double(1),
                    ]),
                ]
            ),
            memory: memory,
            video: video,
            photo: nil
        )
        #expect(invalidRangeOrder.isError == true)
        #expect(firstText(in: invalidRangeOrder).contains("start must be <="))

        let invalidRangeType = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_video_recall",
                arguments: [
                    "query": .string("alpha"),
                    "time_range": .object([
                        "start": .string("bad"),
                        "end": .double(1),
                    ]),
                ]
            ),
            memory: memory,
            video: video,
            photo: nil
        )
        #expect(invalidRangeType.isError == true)
        #expect(firstText(in: invalidRangeType).contains("requires numeric start and end"))

        let invalidLimit = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_video_recall",
                arguments: ["query": .string("alpha"), "limit": .int(0)]
            ),
            memory: memory,
            video: video,
            photo: nil
        )
        #expect(invalidLimit.isError == true)
        #expect(firstText(in: invalidLimit).contains("limit must be between"))

        let emptyResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_video_recall",
                arguments: ["query": .string("alpha"), "limit": .int(5)]
            ),
            memory: memory,
            video: video,
            photo: nil
        )
        #expect(emptyResult.isError != true)
        #expect(firstText(in: emptyResult).isEmpty)
    }
}

@Test
func graphIdentifierAndKindValidationRejectsInvalidInputs() async throws {
    try await withMemory { memory in
        let invalidKey = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_upsert",
                arguments: ["key": "not_namespaced", "kind": "agent"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidKey.isError == true)
        #expect(firstText(in: invalidKey).contains("must be namespaced"))

        let invalidKind = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_upsert",
                arguments: ["key": "agent:codex", "kind": "agent!"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidKind.isError == true)
        #expect(firstText(in: invalidKind).contains("contains invalid characters"))

        let invalidPredicate = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "bad predicate",
                    "object": "x",
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidPredicate.isError == true)
        #expect(firstText(in: invalidPredicate).contains("contains invalid characters"))
    }
}

@Test
func factAssertTypedObjectsRoundTripThroughFactsQuery() async throws {
    try await withMemory { memory in
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_upsert",
                arguments: ["key": "agent:codex", "kind": "agent"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_upsert",
                arguments: ["key": "team:wax", "kind": "team"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )

        let typedValues: [[String: Value]] = [
            ["type": "entity", "value": "team:wax"],
            ["type": "time_ms", "value": 1_700_000_000_000],
            ["type": "data_base64", "value": .string(Data([0x01, 0x02]).base64EncodedString())],
            ["type": "int", "value": "42"],
            ["type": "double", "value": 3.5],
            ["type": "bool", "value": true],
        ]

        for typed in typedValues {
            let result = await WaxMCPTools.handleCall(
                params: .init(
                    name: "wax_fact_assert",
                    arguments: [
                        "subject": "agent:codex",
                        "predicate": "typed_value",
                        "object": .object(typed),
                    ]
                ),
                memory: memory,
                video: nil,
                photo: nil
            )
            #expect(result.isError != true)
        }

        let queried = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "typed_value",
                    "limit": 50,
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(queried.isError != true)
        let text = firstText(in: queried)
        #expect(text.contains("data_base64"))
        #expect(text.contains("time_ms"))
        #expect(text.contains("entity"))
    }
}

@Test
func factAssertRejectsInvalidTypedObjectEnvelopes() async throws {
    try await withMemory { memory in
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_upsert",
                arguments: ["key": "agent:codex", "kind": "agent"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )

        let missingValue = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "typed_value",
                    "object": ["type": "int"],
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(missingValue.isError == true)
        #expect(firstText(in: missingValue).contains("object.value is required"))

        let invalidBase64 = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "typed_value",
                    "object": ["type": "data_base64", "value": "%%not-base64%%"],
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidBase64.isError == true)
        #expect(firstText(in: invalidBase64).contains("valid base64"))

        let unknownType = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "typed_value",
                    "object": ["type": "unknown", "value": "x"],
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(unknownType.isError == true)
        #expect(firstText(in: unknownType).contains("object.type must be one of"))
    }
}

@Test
func rememberMetadataAcceptsScalarValuesAndRejectsNestedValues() async throws {
    try await withMemory { memory in
        let accepted = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": "metadata-scalar-check",
                    "metadata": [
                        "rank": 1,
                        "ratio": 0.5,
                        "active": true,
                        "nullable": .null,
                    ],
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(accepted.isError != true)

        let rejected = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: [
                    "content": "metadata-invalid-check",
                    "metadata": [
                        "nested": .object(["a": .int(1)]),
                    ],
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(rejected.isError == true)
        #expect(firstText(in: rejected).contains("must be a scalar"))
    }
}

@Test
func handoffAndQueryLimitsRejectInvalidRanges() async throws {
    try await withMemory { memory in
        let invalidTasks = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_handoff",
                arguments: [
                    "content": "handoff invalid tasks",
                    "pending_tasks": .array([.string("ok"), .string("  ")]),
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidTasks.isError == true)
        #expect(firstText(in: invalidTasks).contains("must not contain empty values"))

        let invalidRecallLimit = await WaxMCPTools.handleCall(
            params: .init(name: "wax_recall", arguments: ["query": "x", "limit": 0]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidRecallLimit.isError == true)
        #expect(firstText(in: invalidRecallLimit).contains("limit must be between"))

        let invalidFactsLimit = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: ["subject": "agent:codex", "limit": 9999]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidFactsLimit.isError == true)
        #expect(firstText(in: invalidFactsLimit).contains("limit must be between"))
    }
}

@Test
func statsIncludesEmbedderIdentityWhenVectorSearchEnabled() async throws {
    try await withVectorMemory { memory in
        let stats = await WaxMCPTools.handleCall(
            params: .init(name: "wax_stats", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(stats.isError != true)
        let payload = try parseJSONText(in: stats)
        guard let embedder = payload["embedder"] as? [String: Any] else {
            Issue.record("Expected non-null embedder payload")
            return
        }
        #expect((embedder["provider"] as? String) == "stub-text")
        #expect((embedder["model"] as? String) == "stub-v1")
        #expect((embedder["dimensions"] as? Int) == 4)
        #expect((embedder["normalized"] as? Bool) == true)
    }
}

@Test
func factsQueryValidatesAsOfIntegerInputs() async throws {
    try await withMemory { memory in
        let fractional = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: ["as_of": .double(1.5)]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(fractional.isError == true)
        #expect(firstText(in: fractional).contains("as_of must be an integer"))

        let outOfRange = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: ["as_of": .double(1e40)]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(outOfRange.isError == true)
        #expect(firstText(in: outOfRange).contains("as_of is out of range"))

        let invalidString = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_facts_query",
                arguments: ["as_of": .string("not-a-number")]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidString.isError == true)
        #expect(firstText(in: invalidString).contains("must be an integer"))
    }
}

@Test
func factToolsParseBooleanCommitFromStrings() async throws {
    try await withMemory { memory in
        let upsert = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_upsert",
                arguments: ["key": "agent:codex", "kind": "agent", "commit": "yes"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(upsert.isError != true)

        let assertNoCommit = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "status",
                    "object": "active",
                    "commit": "off",
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(assertNoCommit.isError != true)

        let invalidBool = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "status",
                    "object": "active",
                    "commit": "maybe",
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidBool.isError == true)
        #expect(firstText(in: invalidBool).contains("commit must be a boolean"))
    }
}

@Test
func factAssertParsesPrimitiveAndLegacyTypedObjectShapes() async throws {
    try await withMemory { memory in
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_upsert",
                arguments: ["key": "agent:codex", "kind": "agent"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_entity_upsert",
                arguments: ["key": "team:wax", "kind": "team"]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )

        let primitiveInt = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "version",
                    "object": 7,
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(primitiveInt.isError != true)

        let primitiveDouble = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "confidence",
                    "object": 0.75,
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(primitiveDouble.isError != true)

        let primitiveBool = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "enabled",
                    "object": true,
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(primitiveBool.isError != true)

        let legacyEntity = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "member_of",
                    "object": ["entity": "team:wax"],
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(legacyEntity.isError != true)

        let legacyTime = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "started_at",
                    "object": ["time_ms": 1_700_000_000_000],
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(legacyTime.isError != true)

        let legacyData = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "blob",
                    "object": ["data_base64": .string(Data([0xAA, 0xBB]).base64EncodedString())],
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(legacyData.isError != true)

        let invalidPrimitive = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "broken",
                    "object": .array([.int(1)]),
                ]
            ),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(invalidPrimitive.isError == true)
        #expect(firstText(in: invalidPrimitive).contains("object must be a primitive or typed object"))
    }
}

@Test
func videoRecallSerializesRowsFromSeededVideoStore() async throws {
    try await withMemoryAndVideo(seedVideoData: true) { memory, video in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_video_recall",
                arguments: ["query": "beta", "limit": 5]
            ),
            memory: memory,
            video: video,
            photo: nil
        )
        #expect(result.isError != true)
        let text = firstText(in: result)
        #expect(text.contains("\"videoSource\":\"photos\""))
        #expect(text.contains("\"videoSource\":\"file\""))
        #expect(text.contains("\"videoId\":\"photos-seeded\""))
        #expect(text.contains("\"videoId\":\"file-seeded\""))
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

private func seedVideoStore(at url: URL) async throws {
    let wax = try await Wax.create(at: url)
    let sessionConfig = WaxSession.Config(
        enableTextSearch: true,
        enableVectorSearch: true,
        enableStructuredMemory: false,
        vectorEnginePreference: .cpuOnly,
        vectorMetric: .cosine,
        vectorDimensions: 4
    )
    let session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

    let captureMs: Int64 = 1_700_000_000_000

    func putRoot(videoID: VideoID) async throws -> UInt64 {
        var meta = Metadata()
        meta.entries[VideoMetadataKey.source.rawValue] = (videoID.source == .photos) ? "photos" : "file"
        meta.entries[VideoMetadataKey.sourceID.rawValue] = videoID.id
        meta.entries[VideoMetadataKey.captureMs.rawValue] = String(captureMs)
        meta.entries[VideoMetadataKey.durationMs.rawValue] = "1000"
        meta.entries[VideoMetadataKey.isLocal.rawValue] = "true"
        meta.entries[VideoMetadataKey.pipelineVersion.rawValue] = "seeded"
        return try await session.put(
            Data(),
            embedding: [1, 0, 0, 0],
            options: FrameMetaSubset(kind: VideoFrameKind.root.rawValue, metadata: meta),
            compression: .plain,
            timestampMs: captureMs
        )
    }

    func putSegment(rootID: UInt64, videoID: VideoID, transcript: String) async throws {
        var meta = Metadata()
        meta.entries[VideoMetadataKey.source.rawValue] = (videoID.source == .photos) ? "photos" : "file"
        meta.entries[VideoMetadataKey.sourceID.rawValue] = videoID.id
        meta.entries[VideoMetadataKey.captureMs.rawValue] = String(captureMs)
        meta.entries[VideoMetadataKey.isLocal.rawValue] = "true"
        meta.entries[VideoMetadataKey.pipelineVersion.rawValue] = "seeded"
        meta.entries[VideoMetadataKey.segmentIndex.rawValue] = "0"
        meta.entries[VideoMetadataKey.segmentCount.rawValue] = "1"
        meta.entries[VideoMetadataKey.segmentStartMs.rawValue] = "0"
        meta.entries[VideoMetadataKey.segmentEndMs.rawValue] = "1000"
        meta.entries[VideoMetadataKey.segmentMidMs.rawValue] = "500"
        let segmentID = try await session.put(
            Data(transcript.utf8),
            embedding: [1, 0, 0, 0],
            options: FrameMetaSubset(
                kind: VideoFrameKind.segment.rawValue,
                role: .blob,
                parentId: rootID,
                metadata: meta
            ),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: segmentID, text: transcript)
    }

    let fileID = VideoID(source: .file, id: "file-seeded")
    let photosID = VideoID(source: .photos, id: "photos-seeded")
    let fileRoot = try await putRoot(videoID: fileID)
    let photosRoot = try await putRoot(videoID: photosID)
    try await putSegment(rootID: fileRoot, videoID: fileID, transcript: "beta file transcript")
    try await putSegment(rootID: photosRoot, videoID: photosID, transcript: "beta photos transcript")

    try await session.commit()
    await session.close()
    try await wax.close()
}

private func withMemoryAndVideo(
    seedVideoData: Bool = false,
    _ body: @Sendable (MemoryOrchestrator, VideoRAGOrchestrator) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-video-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let memoryURL = root.appendingPathComponent("memory.mv2s", isDirectory: false)
    let videoURL = root.appendingPathComponent("video.mv2s", isDirectory: false)

    var memoryConfig = OrchestratorConfig.default
    memoryConfig.enableVectorSearch = false
    memoryConfig.enableStructuredMemory = true
    memoryConfig.chunking = .tokenCount(targetTokens: 16, overlapTokens: 2)
    memoryConfig.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .textOnly
    )

    var videoConfig = VideoRAGConfig.default
    videoConfig.vectorEnginePreference = .cpuOnly
    videoConfig.includeThumbnailsInContext = false

    if seedVideoData {
        try await seedVideoStore(at: videoURL)
    }

    let memory = try await MemoryOrchestrator(at: memoryURL, config: memoryConfig)
    let video = try await VideoRAGOrchestrator(
        storeURL: videoURL,
        config: videoConfig,
        embedder: StubVideoEmbedder()
    )

    var deferredError: Error?

    do {
        try await body(memory, video)
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

    do {
        try await video.flush()
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
        .appendingPathExtension("mv2s")
    defer { try? FileManager.default.removeItem(at: url) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.enableStructuredMemory = true

    let memory = try await MemoryOrchestrator(at: url, config: config, embedder: StubTextEmbedder())
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
