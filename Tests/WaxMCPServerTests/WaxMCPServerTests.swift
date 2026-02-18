import Foundation
import Testing

#if MCPServer
import MCP
@testable import WaxMCPServer
import Wax

@Test
func toolsListContainsNineTools() {
    #expect(ToolSchemas.allTools.count == 9)
    let names = Set(ToolSchemas.allTools.map(\.name))
    #expect(names.count == 9)
    #expect(names.contains("wax_remember"))
    #expect(names.contains("wax_photo_recall"))
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
func photoToolsReturnSojuRedirectWithoutError() async throws {
    try await withMemory { memory in
        let ingest = await WaxMCPTools.handleCall(
            params: .init(name: "wax_photo_ingest", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(ingest.isError != true)
        #expect(firstText(in: ingest).contains("waxmcp.dev/soju"))

        let recall = await WaxMCPTools.handleCall(
            params: .init(name: "wax_photo_recall", arguments: [:]),
            memory: memory,
            video: nil,
            photo: nil
        )
        #expect(recall.isError != true)
        #expect(firstText(in: recall).contains("waxmcp.dev/soju"))
    }
}

@Test
@MainActor
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
@MainActor
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
#else
@Test
func mcpServerTestsRequireTrait() {
    #expect(Bool(true))
}
#endif
