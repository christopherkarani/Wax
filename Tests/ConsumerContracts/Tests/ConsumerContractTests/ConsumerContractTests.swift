import Foundation
import Testing
import Wax

actor ContractEmbedder: EmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "contract",
        model: "v1",
        dimensions: 4,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        text.localizedCaseInsensitiveContains("password")
            ? [1, 0, 0, 0]
            : [0, 1, 0, 0]
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
