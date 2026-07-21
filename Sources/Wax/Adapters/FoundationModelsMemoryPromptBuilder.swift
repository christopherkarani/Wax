import Foundation

/// How recalled memory is woven into a Foundation Models request prompt.
public enum MemoryInjectionStyle: String, Sendable, Equatable {
    /// Wrap memory and the user prompt in `<wax_memory>` / `<user_prompt>` tags.
    case xmlTags
    /// Plain-text bullet list of memory items (no XML tags).
    case plainBullets
    /// Memory section is returned separately as ``PreparedMemoryPrompt/memoryAppendix`` for
    /// session instructions injection; ``PreparedMemoryPrompt/prompt`` is the bare user text.
    /// When there is no memory, `prompt` is the user text alone and `memoryAppendix` is `nil`.
    case instructionsAppendix
}

/// Result of preparing a memory-augmented prompt, including budget accounting.
public struct PreparedMemoryPrompt: Sendable, Equatable {
    public var prompt: String
    public var includedItemCount: Int
    public var recalledItemCount: Int
    public var truncatedByBudget: Bool
    /// Memory section for session-instructions injection (``MemoryInjectionStyle/instructionsAppendix``).
    /// `nil` for prompt-combined styles or when no memory items were included.
    public var memoryAppendix: String?

    public init(
        prompt: String,
        includedItemCount: Int,
        recalledItemCount: Int,
        truncatedByBudget: Bool,
        memoryAppendix: String? = nil
    ) {
        self.prompt = prompt
        self.includedItemCount = includedItemCount
        self.recalledItemCount = recalledItemCount
        self.truncatedByBudget = truncatedByBudget
        self.memoryAppendix = memoryAppendix
    }
}

/// Formats recalled Wax context into a prompt block suitable for Foundation Models requests.
public struct FoundationModelsMemoryPromptBuilder: Sendable, Equatable {
    public var maxItems: Int
    /// Optional character budget over item text only (`nil` = unlimited beyond `maxItems`).
    public var maxMemoryCharacters: Int?
    public var includeScores: Bool
    public var injectionStyle: MemoryInjectionStyle

    public init(
        maxItems: Int = 8,
        maxMemoryCharacters: Int? = nil,
        includeScores: Bool = false,
        injectionStyle: MemoryInjectionStyle = .xmlTags
    ) {
        self.maxItems = maxItems
        self.maxMemoryCharacters = maxMemoryCharacters
        self.includeScores = includeScores
        self.injectionStyle = injectionStyle
    }

    public static let `default` = FoundationModelsMemoryPromptBuilder()

    public func build(userPrompt: String, context: RAGContext) -> String {
        prepare(userPrompt: userPrompt, context: context).prompt
    }

    public func prepare(userPrompt: String, context: RAGContext) -> PreparedMemoryPrompt {
        let cleanedPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptBody = cleanedPrompt.isEmpty ? userPrompt : cleanedPrompt
        let recalledItemCount = context.items.count

        let selection = selectItems(from: context.items)
        guard !selection.texts.isEmpty else {
            return PreparedMemoryPrompt(
                prompt: promptBody,
                includedItemCount: 0,
                recalledItemCount: recalledItemCount,
                truncatedByBudget: selection.truncatedByBudget,
                memoryAppendix: nil
            )
        }

        // instructionsAppendix: keep the per-turn prompt as bare user text and surface
        // the memory block separately so the session can inject it into instructions.
        if injectionStyle == .instructionsAppendix {
            let appendix = formatMemoryAppendix(query: context.query, items: selection.texts)
            return PreparedMemoryPrompt(
                prompt: promptBody,
                includedItemCount: selection.texts.count,
                recalledItemCount: recalledItemCount,
                truncatedByBudget: selection.truncatedByBudget,
                memoryAppendix: appendix
            )
        }

        let prompt = formatPrompt(
            promptBody: promptBody,
            query: context.query,
            items: selection.texts,
            style: injectionStyle
        )
        return PreparedMemoryPrompt(
            prompt: prompt,
            includedItemCount: selection.texts.count,
            recalledItemCount: recalledItemCount,
            truncatedByBudget: selection.truncatedByBudget,
            memoryAppendix: nil
        )
    }

    // MARK: - Budget selection

    private struct SelectedItem: Sendable, Equatable {
        var item: RAGContext.Item
        var displayText: String
    }

    private struct Selection {
        var texts: [SelectedItem]
        var truncatedByBudget: Bool
    }

    private func selectItems(from items: [RAGContext.Item]) -> Selection {
        let itemLimit = max(0, maxItems)
        let candidates = Array(items.prefix(itemLimit))
        let remainderBeyondMaxItems = items.count > itemLimit
        guard !candidates.isEmpty else {
            return Selection(texts: [], truncatedByBudget: false)
        }

        guard let budget = maxMemoryCharacters else {
            let selected = candidates.map { SelectedItem(item: $0, displayText: $0.text) }
            // Hitting maxItems while more items exist is an item limit, not a char budget.
            return Selection(texts: selected, truncatedByBudget: false)
        }

        var remaining = max(0, budget)
        var selected: [SelectedItem] = []
        var truncatedByBudget = false

        for item in candidates {
            let text = item.text
            let count = text.count
            if count <= remaining {
                selected.append(SelectedItem(item: item, displayText: text))
                remaining -= count
                continue
            }
            if remaining > 0 {
                let truncated = Self.truncate(text, maxCharacters: remaining)
                selected.append(SelectedItem(item: item, displayText: truncated))
                remaining = 0
                truncatedByBudget = true
            } else {
                truncatedByBudget = true
            }
            // Stop once the next item would exceed (or remaining is exhausted after truncate).
            break
        }

        if !truncatedByBudget {
            let usedAllBudgetCandidates = selected.count < candidates.count
            let moreBeyondPrefix = remainderBeyondMaxItems
            // Character budget caused early stop among candidates we intended to include.
            if usedAllBudgetCandidates {
                truncatedByBudget = true
            }
            // Remainder beyond maxItems is not a character-budget truncation.
            _ = moreBeyondPrefix
        }

        // If we included every candidate up to maxItems but budget would have blocked
        // additional items past maxItems, that is maxItems — leave truncatedByBudget false
        // unless we truncated text or stopped mid-candidates.
        return Selection(texts: selected, truncatedByBudget: truncatedByBudget)
    }

    /// Self-contained truncation (mirrors `WaxMemoryToolRenderer.truncate` style).
    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        guard text.count > maxCharacters else { return text }
        let truncated = text.prefix(maxCharacters)
        return "\(truncated)…"
    }

    // MARK: - Formatting

    private func formatPrompt(
        promptBody: String,
        query: String,
        items: [SelectedItem],
        style: MemoryInjectionStyle
    ) -> String {
        switch style {
        case .xmlTags:
            return formatXML(promptBody: promptBody, query: query, items: items)
        case .plainBullets:
            return formatPlainBullets(promptBody: promptBody, query: query, items: items)
        case .instructionsAppendix:
            // Combined form kept for standalone `build` fallbacks; `prepare` splits this style.
            return formatInstructionsAppendix(promptBody: promptBody, query: query, items: items)
        }
    }

    /// Memory-only section for ``MemoryInjectionStyle/instructionsAppendix`` (no user prompt).
    private func formatMemoryAppendix(query: String, items: [SelectedItem]) -> String {
        var lines: [String] = [
            "Recalled memory context (apply only when relevant to the user request):",
            "Memory query: \(query)",
        ]
        for (index, entry) in items.enumerated() {
            lines.append(numberedLine(index: index + 1, entry: entry))
        }
        return lines.joined(separator: "\n")
    }

    private func formatXML(
        promptBody: String,
        query: String,
        items: [SelectedItem]
    ) -> String {
        var lines: [String] = [
            "<wax_memory>",
            "Use the following memory context only when it is relevant to the user request.",
            "Memory query: \(query)",
            "Memory items:",
        ]
        for (index, entry) in items.enumerated() {
            lines.append(numberedLine(index: index + 1, entry: entry))
        }
        lines += [
            "</wax_memory>",
            "",
            "<user_prompt>",
            promptBody,
            "</user_prompt>",
        ]
        return lines.joined(separator: "\n")
    }

    private func formatPlainBullets(
        promptBody: String,
        query: String,
        items: [SelectedItem]
    ) -> String {
        var lines: [String] = [
            "Relevant memory (use only when it helps the user request):",
            "Memory query: \(query)",
        ]
        for entry in items {
            lines.append("- \(itemLabel(entry)) \(entry.displayText)")
        }
        lines += [
            "",
            promptBody,
        ]
        return lines.joined(separator: "\n")
    }

    private func formatInstructionsAppendix(
        promptBody: String,
        query: String,
        items: [SelectedItem]
    ) -> String {
        // Suitable to append to session instructions; still pairs memory with the user prompt
        // for standalone `build` / `prepare` use. Sessions may split these later.
        var lines: [String] = [
            "Recalled memory context (apply only when relevant to the user request):",
            "Memory query: \(query)",
        ]
        for (index, entry) in items.enumerated() {
            lines.append(numberedLine(index: index + 1, entry: entry))
        }
        lines += [
            "",
            "User request:",
            promptBody,
        ]
        return lines.joined(separator: "\n")
    }

    private func numberedLine(index: Int, entry: SelectedItem) -> String {
        "\(index). \(itemLabel(entry)) \(entry.displayText)"
    }

    private func itemLabel(_ entry: SelectedItem) -> String {
        let kind = kindLabel(entry.item.kind)
        let sources = entry.item.sources.map(\.rawValue).joined(separator: ",")
        let scoreSuffix = includeScores ? String(format: " score=%.4f", entry.item.score) : ""
        return "[\(kind)|\(sources)\(scoreSuffix)]"
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
    /// Controls whether turns are written back into the Wax store.
    public enum PersistencePolicy: Sendable, Equatable {
        case none
        case userOnly
        case assistantOnly
        case userAndAssistant
        /// Do not auto-persist chat turns; only tools / explicit remember paths write facts.
        case durableFactsOnly

        public var shouldPersistUser: Bool {
            self == .userOnly || self == .userAndAssistant
        }

        public var shouldPersistAssistant: Bool {
            self == .assistantOnly || self == .userAndAssistant
        }
    }

    /// How Wax memory is exposed to Foundation Models.
    public enum ContextStrategy: Sendable, Equatable {
        /// Inject recalled memory into the prompt before each generation.
        case promptAugmentation
        /// Register Wax memory tools and let the model call them.
        case tools
        /// Inject relevant memory and also register tools for active store/recall.
        case hybrid
    }

    /// How structured (non-string) model outputs are serialized when persisted.
    public enum StructuredPersistence: Sendable, Equatable {
        /// Use `String(describing:)` (historical default).
        case stringDescribing
        /// Prefer a JSON-like encoding when available.
        case jsonLike
        /// Do not persist structured outputs.
        case disabled
    }

    public var persistencePolicy: PersistencePolicy
    public var contextStrategy: ContextStrategy
    public var embeddingPolicy: Memory.EmbeddingPolicy
    public var promptBuilder: FoundationModelsMemoryPromptBuilder
    public var toolConfig: WaxMemoryToolConfig
    public var includeMemoryTools: Bool
    public var userMetadata: [String: String]
    public var assistantMetadata: [String: String]
    /// Injection style applied at prepare time (overrides ``promptBuilder``'s style).
    ///
    /// Mutating this after init — without replacing ``promptBuilder`` — still affects
    /// ``WaxFoundationModelSession/preparePromptDetailed(for:)``.
    public var injectionStyle: MemoryInjectionStyle
    /// Character budget applied at prepare time via ``promptBuilder``'s
    /// `maxMemoryCharacters` (`nil` = unlimited). Overrides the builder's budget field.
    public var memoryCharacterBudget: Int?
    public var structuredPersistence: StructuredPersistence
    /// Which Foundation Models tool kit to register when `includeMemoryTools` is true.
    public var toolKit: WaxMemoryToolKit

    public init(
        persistencePolicy: PersistencePolicy = .userAndAssistant,
        contextStrategy: ContextStrategy = .hybrid,
        embeddingPolicy: Memory.EmbeddingPolicy = .automatic,
        promptBuilder: FoundationModelsMemoryPromptBuilder? = nil,
        toolConfig: WaxMemoryToolConfig = .default,
        includeMemoryTools: Bool? = nil,
        userMetadata: [String: String] = [
            "wax.channel": "foundation_models",
            "wax.role": "user",
        ],
        assistantMetadata: [String: String] = [
            "wax.channel": "foundation_models",
            "wax.role": "assistant",
        ],
        injectionStyle: MemoryInjectionStyle = .xmlTags,
        memoryCharacterBudget: Int? = 1_200,
        structuredPersistence: StructuredPersistence = .stringDescribing,
        toolKit: WaxMemoryToolKit = .focused
    ) {
        self.persistencePolicy = persistencePolicy
        self.contextStrategy = contextStrategy
        self.embeddingPolicy = embeddingPolicy
        self.toolConfig = toolConfig
        // Default tool registration follows the chosen context strategy.
        self.includeMemoryTools = includeMemoryTools ?? (contextStrategy != .promptAugmentation)
        self.userMetadata = userMetadata
        self.assistantMetadata = assistantMetadata
        self.injectionStyle = injectionStyle
        self.memoryCharacterBudget = memoryCharacterBudget
        self.structuredPersistence = structuredPersistence
        self.toolKit = toolKit

        if let promptBuilder {
            self.promptBuilder = promptBuilder
        } else {
            // Production-safer hybrid defaults: fewer items + character budget.
            self.promptBuilder = FoundationModelsMemoryPromptBuilder(
                maxItems: 4,
                maxMemoryCharacters: memoryCharacterBudget,
                includeScores: false,
                injectionStyle: injectionStyle
            )
        }
    }

    /// Production-friendly hybrid defaults with a tighter memory budget.
    public static let `default` = FoundationModelsMemorySessionConfig()

    /// Tools-only: no prompt augmentation; compact remember/recall tools for small windows.
    public static let toolsOnlyCompact = FoundationModelsMemorySessionConfig(
        contextStrategy: .tools,
        promptBuilder: FoundationModelsMemoryPromptBuilder(
            maxItems: 4,
            maxMemoryCharacters: 800,
            injectionStyle: .xmlTags
        ),
        includeMemoryTools: true,
        memoryCharacterBudget: 800,
        toolKit: .compact
    )

    /// Prompt-only light: inject a small memory block, no tools.
    public static let promptOnlyLight = FoundationModelsMemorySessionConfig(
        contextStrategy: .promptAugmentation,
        promptBuilder: FoundationModelsMemoryPromptBuilder(
            maxItems: 3,
            maxMemoryCharacters: 800,
            injectionStyle: .xmlTags
        ),
        includeMemoryTools: false,
        memoryCharacterBudget: 800
    )

    /// Balanced hybrid: inject up to 4 items (~1200 chars) and register focused memory tools.
    public static let hybridBalanced = FoundationModelsMemorySessionConfig(
        contextStrategy: .hybrid,
        promptBuilder: FoundationModelsMemoryPromptBuilder(
            maxItems: 4,
            maxMemoryCharacters: 1_200,
            injectionStyle: .xmlTags
        ),
        includeMemoryTools: true,
        memoryCharacterBudget: 1_200,
        toolKit: .focused
    )

    public var shouldAugmentPrompt: Bool {
        switch contextStrategy {
        case .promptAugmentation, .hybrid:
            return true
        case .tools:
            return false
        }
    }
}
