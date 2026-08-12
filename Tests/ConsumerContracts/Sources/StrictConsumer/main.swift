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
        let url = FileManager.default.temporaryDirectory
            .appending(path: "wax-contract-\(UUID().uuidString).wax")
        let memory = try await Memory(at: url) {
            $0.embedding = .custom(ContractEmbedder())
        }
        try await memory.save("Password reset instructions are in account settings.")
        let result = try await memory.search("recover password") {
            $0.mode = .vectorOnly
            $0.topK = 1
        }
        precondition(result.items.first?.text.contains("Password reset") == true)
        precondition(result.diagnostics?.effectiveMode == "vector")
        try await memory.close()
    }
}
