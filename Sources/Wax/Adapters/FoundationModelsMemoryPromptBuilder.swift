import Foundation

/// Formats recalled Wax context into a prompt block suitable for Foundation Models requests.
public struct FoundationModelsMemoryPromptBuilder: Sendable, Equatable {
    public var maxItems: Int
    public var includeScores: Bool

    public init(maxItems: Int = 8, includeScores: Bool = false) {
        self.maxItems = maxItems
        self.includeScores = includeScores
    }

    public static let `default` = FoundationModelsMemoryPromptBuilder()

    public func build(userPrompt: String, context: RAGContext) -> String {
        let cleanedPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptBody = cleanedPrompt.isEmpty ? userPrompt : cleanedPrompt

        let itemLimit = max(0, maxItems)
        let limitedItems = Array(context.items.prefix(itemLimit))
        guard !limitedItems.isEmpty else { return promptBody }

        var lines: [String] = [
            "<wax_memory>",
            "Use the following memory context only when it is relevant to the user request.",
            "Memory query: \(context.query)",
            "Memory items:"
        ]

        for (index, item) in limitedItems.enumerated() {
            let kind = kindLabel(item.kind)
            let sources = item.sources.map(\.rawValue).joined(separator: ",")
            let scoreSuffix = includeScores ? String(format: " score=%.4f", item.score) : ""
            lines.append("\(index + 1). [\(kind)|\(sources)\(scoreSuffix)] \(item.text)")
        }

        lines += [
            "</wax_memory>",
            "",
            "<user_prompt>",
            promptBody,
            "</user_prompt>"
        ]
        return lines.joined(separator: "\n")
    }

    private func kindLabel(_ kind: RAGContext.ItemKind) -> String {
        switch kind {
        case .snippet:
            return "snippet"
        case .expanded:
            return "expanded"
        case .surrogate:
            return "surrogate"
        }
    }
}

/// Configuration for memory-augmented Foundation Models chat.
public struct FoundationModelsMemorySessionConfig: Sendable, Equatable {
    public enum PersistencePolicy: Sendable, Equatable {
        case none
        case userOnly
        case assistantOnly
        case userAndAssistant

        var shouldPersistUser: Bool {
            self == .userOnly || self == .userAndAssistant
        }

        var shouldPersistAssistant: Bool {
            self == .assistantOnly || self == .userAndAssistant
        }
    }

    public var persistencePolicy: PersistencePolicy
    public var queryEmbeddingPolicy: MemoryOrchestrator.QueryEmbeddingPolicy
    public var promptBuilder: FoundationModelsMemoryPromptBuilder
    public var userMetadata: [String: String]
    public var assistantMetadata: [String: String]

    public init(
        persistencePolicy: PersistencePolicy = .userAndAssistant,
        queryEmbeddingPolicy: MemoryOrchestrator.QueryEmbeddingPolicy = .ifAvailable,
        promptBuilder: FoundationModelsMemoryPromptBuilder = .default,
        userMetadata: [String: String] = [
            "wax.channel": "foundation_models",
            "wax.role": "user",
        ],
        assistantMetadata: [String: String] = [
            "wax.channel": "foundation_models",
            "wax.role": "assistant",
        ]
    ) {
        self.persistencePolicy = persistencePolicy
        self.queryEmbeddingPolicy = queryEmbeddingPolicy
        self.promptBuilder = promptBuilder
        self.userMetadata = userMetadata
        self.assistantMetadata = assistantMetadata
    }

    public static let `default` = FoundationModelsMemorySessionConfig()
}
