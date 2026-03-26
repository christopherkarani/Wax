import Foundation
import Wax

extension StoreSession {
    /// Open a store, run `body`, and guarantee `close()` is awaited before returning.
    ///
    /// This replaces the `defer { Task { try? await memory.close() } }` anti-pattern
    /// used across CLI commands. That pattern creates an unstructured task that is
    /// orphaned when the CLI process exits before the task runs, meaning close() may
    /// never be called and any pending WAL writes can be lost.
    ///
    /// This helper uses a structured do/catch so close() is always awaited on both
    /// the success and error paths.
    static func withOpen<T: Sendable>(
        at url: URL,
        noEmbedder: Bool = false,
        skipPrewarm: Bool = false,
        embedderChoice: EmbedderChoice = .minilm,
        requireVector: Bool = false,
        body: (MemoryOrchestrator) async throws -> T
    ) async throws -> T {
        let memory = try await open(
            at: url,
            noEmbedder: noEmbedder,
            skipPrewarm: skipPrewarm,
            embedderChoice: embedderChoice,
            requireVector: requireVector
        )
        do {
            let result = try await body(memory)
            try await memory.close()
            return result
        } catch {
            try? await memory.close()
            throw error
        }
    }
}
