#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import Wax
import WaxVectorSearch

@Suite("FoundationModelDiagnosticsContractTests")
struct FoundationModelDiagnosticsContractTests {
    @Test
    func prepareAndRespondPreserveRetrievalDiagnosticsOnVectorToTextDegradation() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            var memoryConfig = Memory.Config.default
            memoryConfig.embedding = .custom(QueryFailEmbedder())
            memoryConfig.enableVectorSearch = true
            let memory = try await Memory(at: url, config: memoryConfig)
            try await memory.save("User prefers the cerulean-77 onboard color code.")

            var configuration = FoundationModelsMemorySessionConfig.promptOnlyLight
            configuration.embeddingPolicy = .automatic
            configuration.persistencePolicy = .none
            configuration.toolConfig.fallbackToTextOnVectorFailure = true
            configuration.toolConfig.searchAlpha = 0.25

            let generator = ControllableFoundationModelGenerator()
            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: generator
            )

            let prepared = try await session.preparePromptDetailed(
                for: "What is my favorite onboard color code?"
            )
            let diagnostics = try #require(prepared.retrievalDiagnostics)
            #expect(diagnostics.requestedMode.contains("hybrid"))
            #expect(diagnostics.effectiveMode == "text")
            #expect(diagnostics.queryEmbeddingState == .failed)
            #expect(prepared.recalledItemCount >= 1)
            #expect(prepared.estimatedPreparedCharacters == prepared.prompt.count)
            #expect(prepared.estimatedPreparedCharacters > 0)
            #expect(prepared.resetTranscriptForContext == false)
            #expect(prepared.truncationStrategy == "none" || prepared.truncationStrategy == "characterBudget")
            #expect(prepared.estimatedContextTokens >= 0)
            #expect(prepared.preparedPromptTokenCount >= 0)

            let response = try await session.respondDetailed(
                to: "What is my favorite onboard color code?"
            )
            let responseDiagnostics = try #require(response.retrievalDiagnostics)
            #expect(responseDiagnostics.requestedMode == diagnostics.requestedMode)
            #expect(responseDiagnostics.effectiveMode == "text")
            #expect(responseDiagnostics.queryEmbeddingState == .failed)
            #expect(response.estimatedPreparedCharacters == prepared.estimatedPreparedCharacters)
            #expect(response.resetTranscriptForContext == false)
            #expect(response.truncationStrategy == prepared.truncationStrategy)
            #expect(response.recalledItemCount == prepared.recalledItemCount)

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func estimatedPreparedCharactersCountsMemoryWrappers() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
            try await memory.save("User editor preference is Helix.")

            var configuration = FoundationModelsMemorySessionConfig.promptOnlyLight
            configuration.embeddingPolicy = .never
            configuration.persistencePolicy = .none
            configuration.promptBuilder = FoundationModelsMemoryPromptBuilder(
                maxItems: 4,
                maxMemoryCharacters: 1_200,
                injectionStyle: .xmlTags
            )

            let session = WaxFoundationModelSession(
                memory: memory,
                configuration: configuration,
                generator: ControllableFoundationModelGenerator()
            )
            let userPrompt = "What editor do I prefer?"
            let prepared = try await session.preparePromptDetailed(for: userPrompt)

            #expect(prepared.prompt.contains("<wax_memory>"))
            #expect(prepared.prompt.contains("<user_prompt>"))
            #expect(prepared.estimatedPreparedCharacters == prepared.prompt.count)
            #expect(prepared.estimatedPreparedCharacters > userPrompt.count)
            #expect(prepared.recalledItemCount >= 1)
            if prepared.truncatedByBudget {
                #expect(prepared.truncationStrategy == "characterBudget")
            } else {
                #expect(prepared.truncationStrategy == "none")
            }

            try await session.close()
            try await memory.close()
        }
    }

    @Test
    func openFoundationModelsToolsOwnsStoreAndExposesClose() async throws {
        guard #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) else { return }

        try await TempFiles.withTempFile { url in
            var config = Memory.Config.default
            config.enableVectorSearch = false
            let toolSession = try await Memory.openFoundationModelsTools(
                at: url,
                config: config,
                kit: .focused
            )
            #expect(toolSession.tools.map(\.name).sorted() == ["waxRecall", "waxRemember", "waxSearch"])

            let remember = try #require(toolSession.tools.first { $0.name == "waxRemember" } as? WaxRememberTool)
            let stored = try await remember.call(
                arguments: .init(content: "Opened via owning tool session.")
            )
            #expect(stored.isSuccess)

            try await toolSession.flush()
            try await toolSession.close()
        }
    }
}

private struct QueryFailEmbedder: QueryAwareEmbeddingProvider {
    let dimensions = 2
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Mock",
        model: "QueryFail",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b: Float = 0.5
        let norm = (a * a + b * b).squareRoot()
        return [a / max(norm, 1e-6), b / max(norm, 1e-6)]
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        _ = text
        throw MockEmbedderError.forcedFailure
    }
}
#endif
