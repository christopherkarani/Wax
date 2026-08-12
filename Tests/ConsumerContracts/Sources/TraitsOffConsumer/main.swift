import Foundation
import Wax

@main
struct TraitsOffConsumer {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "wax-traits-off-\(UUID().uuidString).wax")
        // Value-form APIs only: this fixture must compile today. Closure-form
        // configuration is reserved for StrictConsumer (expected-red until Task 2).
        let memory = try await Memory(at: url)
        try await memory.save("Password reset instructions are in account settings.")
        try await memory.flush()
        let result = try await memory.search("recover password")
        let stats = await memory.stats()
        precondition(stats.vectorSearchEnabled == false)
        precondition(stats.queryEmbedderConfigured == false)
        precondition(result.diagnostics?.effectiveMode == "text")
        try await memory.close()
    }
}
