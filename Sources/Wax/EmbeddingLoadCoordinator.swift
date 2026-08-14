import Foundation
import WaxCore

package struct EmbeddingLoadKey: Hashable, Sendable {
    package let provider: String
    package let configuration: String

    package init(provider: String, configuration: String) {
        self.provider = provider
        self.configuration = configuration
    }
}

/// Retains expensive model-load work independently from any one caller's wait budget.
///
/// Core ML compilation is not reliably cancellable. Keeping the unstructured load task
/// here means a timed-out request can return while a later request reuses the same work.
package actor EmbeddingLoadCoordinator {
    package enum WaitError: Error, Sendable, Equatable {
        case timedOut
    }

    private struct Entry: Sendable {
        let id: UUID
        let task: Task<any EmbeddingProvider, any Error>
    }

    private var tasks: [EmbeddingLoadKey: Entry] = [:]

    package init() {}

    package func provider(
        for key: EmbeddingLoadKey,
        timeout: Duration? = nil,
        factory: @escaping @Sendable () async throws -> any EmbeddingProvider
    ) async throws -> any EmbeddingProvider {
        let entry: Entry
        if let existing = tasks[key] {
            entry = existing
        } else {
            let created = Task { try await factory() }
            let newEntry = Entry(id: UUID(), task: created)
            tasks[key] = newEntry
            entry = newEntry
        }

        do {
            let provider: any EmbeddingProvider
            if let timeout {
                provider = try await AsyncTimeout.run(
                    timeout: timeout,
                    operation: "embedding provider load"
                ) {
                    try await entry.task.value
                }
            } else {
                provider = try await entry.task.value
            }
            return provider
        } catch is AsyncTimeout.TimeoutError {
            throw WaitError.timedOut
        } catch {
            if tasks[key]?.id == entry.id {
                tasks[key] = nil
            }
            throw error
        }
    }
}
