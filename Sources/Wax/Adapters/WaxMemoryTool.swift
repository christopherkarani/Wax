#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
package struct WaxMemoryTool: Tool, Sendable {
    package let name: String = "waxMemory"
    package let description: String = """
Manage persistent memory in Wax.
Use action=remember to store content, action=recall to retrieve context, and action=search for ranked hits.
"""

    private let memory: MemoryOrchestrator
    package let config: WaxMemoryToolConfig

    @Generable
    package struct Arguments {
        @Guide(description: "Action to perform: remember, recall, or search.")
        package var action: String

        @Guide(description: "Memory content to store. Required for action=remember.")
        package var content: String?

        @Guide(description: "Query text used by recall/search. Required for action=recall or action=search.")
        package var query: String?

        @Guide(description: "Optional number of results for action=search.")
        package var topK: Int?

        @Guide(description: "Optional hybrid alpha [0,1] for action=search. Higher favors text search.")
        package var alpha: Float?

        package init(
            action: String = "",
            content: String? = nil,
            query: String? = nil,
            topK: Int? = nil,
            alpha: Float? = nil
        ) {
            self.action = action
            self.content = content
            self.query = query
            self.topK = topK
            self.alpha = alpha
        }
    }

    package init(
        memory: MemoryOrchestrator,
        config: WaxMemoryToolConfig = .default
    ) {
        self.memory = memory
        self.config = config
    }

    package func call(arguments: Arguments) async throws -> some PromptRepresentable {
        guard let action = WaxMemoryToolAction.parse(arguments.action) else {
            return output(
                status: "error",
                action: arguments.action,
                text: WaxMemoryToolRenderer.renderError("invalid action. Use remember, recall, or search.")
            )
        }

        do {
            switch action {
            case .remember:
                guard let content = normalizedText(arguments.content), !content.isEmpty else {
                    return output(
                        status: "error",
                        action: action.rawValue,
                        text: WaxMemoryToolRenderer.renderError("content is required for action=remember.")
                    )
                }
                try await memory.remember(content, metadata: config.rememberMetadata)
                return output(
                    status: "ok",
                    action: action.rawValue,
                    text: WaxMemoryToolRenderer.renderRemember(contentLength: content.count)
                )

            case .recall:
                guard let query = normalizedText(arguments.query), !query.isEmpty else {
                    return output(
                        status: "error",
                        action: action.rawValue,
                        text: WaxMemoryToolRenderer.renderError("query is required for action=recall.")
                    )
                }
                let context = try await memory.recall(
                    query: query,
                    embeddingPolicy: config.queryEmbeddingPolicy
                )
                return output(
                    status: "ok",
                    action: action.rawValue,
                    text: WaxMemoryToolRenderer.renderRecall(
                        query: query,
                        context: context,
                        maxItems: config.recallMaxItems,
                        includeScores: config.includeScores,
                        maxItemCharacters: config.maxItemCharacters
                    )
                )

            case .search:
                guard let query = normalizedText(arguments.query), !query.isEmpty else {
                    return output(
                        status: "error",
                        action: action.rawValue,
                        text: WaxMemoryToolRenderer.renderError("query is required for action=search.")
                    )
                }

                let topK = config.topK(arguments.topK)
                let alpha = config.alpha(arguments.alpha)
                let hits = try await memory.search(
                    query: query,
                    mode: .hybrid(alpha: alpha),
                    topK: topK
                )
                return output(
                    status: "ok",
                    action: action.rawValue,
                    text: WaxMemoryToolRenderer.renderSearch(
                        query: query,
                        hits: hits,
                        includeScores: config.includeScores,
                        maxItemCharacters: config.maxItemCharacters
                    )
                )
            }
        } catch {
            return output(
                status: "error",
                action: action.rawValue,
                text: WaxMemoryToolRenderer.renderError("operation failed: \(error.localizedDescription)")
            )
        }
    }

    private func output(status: String, action: String, text: String) -> GeneratedContent {
        GeneratedContent(
            properties: [
                "status": status,
                "action": action,
                "output": text,
            ]
        )
    }
}

@available(macOS 26.0, iOS 26.0, *)
package extension MemoryOrchestrator {
    /// Creates a Foundation Models tool that can remember and retrieve Wax memory.
    func foundationModelsMemoryTool(config: WaxMemoryToolConfig = .default) -> WaxMemoryTool {
        WaxMemoryTool(memory: self, config: config)
    }

    /// Opens a store and returns a Foundation Models memory tool bound to that store.
    static func openFoundationModelsMemoryTool(
        at url: URL,
        config: OrchestratorConfig = .default,
        embedder: (any EmbeddingProvider)? = nil,
        toolConfig: WaxMemoryToolConfig = .default
    ) async throws -> WaxMemoryTool {
        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        return WaxMemoryTool(memory: orchestrator, config: toolConfig)
    }
}

private func normalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
#endif
