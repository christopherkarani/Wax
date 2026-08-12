import Foundation
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

@main
struct StrictConsumer {
    static func main() async throws {
        let storeURL: URL
        let reopenOnly: Bool
        if CommandLine.arguments.count > 1 {
            storeURL = URL(fileURLWithPath: CommandLine.arguments[1])
            reopenOnly = true
        } else {
            storeURL = FileManager.default.temporaryDirectory
                .appending(path: "wax-contract-\(UUID().uuidString).wax")
            reopenOnly = false
        }

        let configure: @Sendable (inout Memory.Config) -> Void = {
            $0.embedding = .custom(ContractEmbedder())
        }
        let searchConfigure: @Sendable (inout Memory.SearchOptions) -> Void = {
            $0.mode = .vectorOnly
            $0.topK = 1
        }

        if reopenOnly {
            try await verifySearch(at: storeURL, configure: configure, searchConfigure: searchConfigure)
            print("WAX_STRICT_REOPEN_OK=\(storeURL.path)")
            return
        }

        let memory = try await Memory(at: storeURL, configure: configure)
        try await memory.save("Password reset instructions are in account settings.")
        // Trailing closure from @main: requires the public search API to be @Sendable.
        let first = try await memory.search("recover password") {
            $0.mode = .vectorOnly
            $0.topK = 1
        }
        precondition(first.items.first?.text.contains("Password reset") == true)
        precondition(first.diagnostics?.effectiveMode == "vector")
        try await memory.close()

        let reopened = try await Memory(at: storeURL, configure: configure)
        try await searchAndVerify(reopened, searchConfigure: searchConfigure)
        try await reopened.close()

        print("WAX_STRICT_STORE=\(storeURL.path)")
    }

    private static func searchAndVerify(
        _ memory: Memory,
        searchConfigure: @Sendable (inout Memory.SearchOptions) -> Void
    ) async throws {
        let result = try await memory.search("recover password", configure: searchConfigure)
        precondition(result.items.first?.text.contains("Password reset") == true)
        precondition(result.diagnostics?.effectiveMode == "vector")
        let stats = await memory.stats()
        precondition(stats.vectorSearchEnabled == true)
        precondition(stats.queryEmbedderConfigured == true)
    }

    private static func verifySearch(
        at url: URL,
        configure: @Sendable (inout Memory.Config) -> Void,
        searchConfigure: @Sendable (inout Memory.SearchOptions) -> Void
    ) async throws {
        let memory = try await Memory(at: url, configure: configure)
        try await searchAndVerify(memory, searchConfigure: searchConfigure)
        try await memory.close()
    }
}
