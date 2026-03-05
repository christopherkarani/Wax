#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
package actor WaxFoundationModelSession {
    private let memory: MemoryOrchestrator
    private let session: LanguageModelSession
    package let configuration: FoundationModelsMemorySessionConfig

    package init(
        memory: MemoryOrchestrator,
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        configuration: FoundationModelsMemorySessionConfig = .default
    ) {
        self.memory = memory
        self.configuration = configuration
        if let instructions {
            self.session = LanguageModelSession(model: model, instructions: instructions)
        } else {
            self.session = LanguageModelSession(model: model)
        }
        self.session.prewarm()
    }

    /// Builds the memory-augmented prompt sent to Foundation Models.
    package func preparePrompt(for userPrompt: String) async throws -> String {
        let context = try await memory.recall(
            query: userPrompt,
            embeddingPolicy: configuration.queryEmbeddingPolicy
        )
        return configuration.promptBuilder.build(userPrompt: userPrompt, context: context)
    }

    /// Generates a text response and optionally persists both sides of the turn.
    package func respond(to userPrompt: String) async throws -> String {
        let prompt = try await preparePrompt(for: userPrompt)
        let response = try await session.respond(to: prompt).content
        try await persistTurn(userPrompt: userPrompt, assistantResponse: response)
        return response
    }

    /// Generates a structured response and optionally persists the turn.
    ///
    /// When assistant persistence is enabled, structured values are persisted using
    /// `String(describing:)` by default.
    package func respond<T: Generable>(to userPrompt: String, generating type: T.Type) async throws -> T {
        let prompt = try await preparePrompt(for: userPrompt)
        let response = try await session.respond(to: prompt, generating: type).content
        try await persistTurn(userPrompt: userPrompt, assistantResponse: String(describing: response))
        return response
    }

    /// Persists content directly into the underlying Wax store.
    package func remember(_ content: String, metadata: [String: String] = [:]) async throws {
        try await memory.remember(content, metadata: metadata)
    }

    /// Recalls memory context directly from the underlying Wax store.
    package func recall(query: String) async throws -> RAGContext {
        try await memory.recall(query: query)
    }

    /// Closes the underlying memory orchestrator.
    package func close() async throws {
        try await memory.close()
    }

    private func persistTurn(userPrompt: String, assistantResponse: String) async throws {
        if configuration.persistencePolicy.shouldPersistUser {
            let trimmedPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrompt.isEmpty {
                try await memory.remember(trimmedPrompt, metadata: configuration.userMetadata)
            }
        }

        if configuration.persistencePolicy.shouldPersistAssistant {
            let trimmedResponse = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedResponse.isEmpty {
                try await memory.remember(trimmedResponse, metadata: configuration.assistantMetadata)
            }
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
package extension MemoryOrchestrator {
    /// Creates a memory-backed Foundation Models session from an existing orchestrator.
    func foundationModelsSession(
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        configuration: FoundationModelsMemorySessionConfig = .default
    ) -> WaxFoundationModelSession {
        WaxFoundationModelSession(
            memory: self,
            model: model,
            instructions: instructions,
            configuration: configuration
        )
    }

    /// Opens a store and returns a memory-backed Foundation Models session.
    static func openFoundationModelsSession(
        at url: URL,
        config: OrchestratorConfig = .default,
        embedder: (any EmbeddingProvider)? = nil,
        model: SystemLanguageModel = .default,
        instructions: String? = nil,
        sessionConfiguration: FoundationModelsMemorySessionConfig = .default
    ) async throws -> WaxFoundationModelSession {
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: embedder
        )
        return WaxFoundationModelSession(
            memory: orchestrator,
            model: model,
            instructions: instructions,
            configuration: sessionConfiguration
        )
    }
}
#endif
