import Foundation
import Testing
import Wax

actor ContractEmbedder: QueryAwareEmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "contract",
        model: "v1",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(_ text: String) async throws -> [Float] {
        text.localizedCaseInsensitiveContains("password")
            ? [1, 0, 0, 0]
            : [0, 1, 0, 0]
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(text)
    }
}

/// Omits `executionMode` so the protocol default (`.mayUseNetwork`) applies.
actor OmittedExecutionModeEmbedder: EmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "omit",
        model: "v1",
        dimensions: 4,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        [1, 0, 0, 0]
    }
}

@Test
func customEmbedderVectorOnlySearchSurvivesReopen() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "wax-contract-test-\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: url) }

    let config = Memory.Config(embedding: .custom(ContractEmbedder()))

    do {
        let memory = try await Memory(at: url, config: config)
        try await memory.save("Unrelated gardening notes about tomatoes.")
        try await memory.save("Password reset instructions are in account settings.")
        try await memory.flush()

        let result = try await memory.search(
            "recover password",
            options: .init(topK: 1, mode: .vectorOnly)
        )
        #expect(result.items.first?.text.contains("Password reset") == true)
        #expect(result.diagnostics?.effectiveMode == "vector")

        let stats = await memory.stats()
        #expect(stats.vectorSearchEnabled == true)
        #expect(stats.queryEmbedderConfigured == true)

        try await memory.close()
    }

    let reopened = try await Memory(at: url, config: Memory.Config(embedding: .custom(ContractEmbedder())))
    let again = try await reopened.search(
        "recover password",
        options: .init(topK: 1, mode: .vectorOnly)
    )
    #expect(again.items.first?.text.contains("Password reset") == true)
    #expect(again.diagnostics?.effectiveMode == "vector")

    let reopenedStats = await reopened.stats()
    #expect(reopenedStats.vectorSearchEnabled == true)
    #expect(reopenedStats.queryEmbedderConfigured == true)

    try await reopened.close()
}

@Test
func queryAwareEmbeddingProviderIsReExportedByImportWax() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "wax-query-aware-contract-\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: url) }

    let provider: any QueryAwareEmbeddingProvider = ContractEmbedder()
    let memory = try await Memory(at: url, config: .init(embedding: .custom(provider)))
    try await memory.save("Password reset instructions are in account settings.")
    try await memory.save("Unrelated gardening notes about tomatoes.")
    let result = try await memory.search(
        "recover password",
        options: .init(topK: 1, mode: .vectorOnly)
    )
    #expect(result.items.first?.text.contains("Password reset") == true)
    try await memory.close()
}

@Test
func omittedExecutionModeIsRejectedWhenRequireOnDeviceProviders() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "wax-omit-mode-contract-\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        _ = try await Memory(
            at: url,
            config: .init(embedding: .custom(OmittedExecutionModeEmbedder()))
        )
        Issue.record("Expected WaxError for a provider that omits executionMode")
    } catch let error as WaxError {
        guard case .io(let message) = error else {
            Issue.record("Expected WaxError.io, got \(error)")
            return
        }
        #expect(message.contains("on-device embedding provider"))
    }
}
